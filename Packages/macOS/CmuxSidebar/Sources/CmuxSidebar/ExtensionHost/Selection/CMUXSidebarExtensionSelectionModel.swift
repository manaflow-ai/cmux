public import ExtensionFoundation
public import Foundation
import Observation
@_spi(CmuxHostTransport) import CmuxExtensionKit

/// Owns the sidebar-extension selection domain: discovers the installed
/// `AppExtensionIdentity` values registered against the cmux sidebar extension
/// point, persists and restores the user's chosen extension, deduplicates the
/// discovered identities, and tracks the disabled/unapproved availability counts
/// surfaced in the empty state.
///
/// This is the selection/availability state previously inlined as `@State` in
/// `CMUXInstalledExtensionSidebarHostView`. The XPC host lifecycle (connection
/// teardown, effective-grant reset, blocked-manifest reset) stays with the view,
/// which owns the live connection, and is injected as the `onSelectedIdentityChange`
/// / `onLoadFailure` closures invoked at the exact points the inlined code ran.
///
/// `@MainActor` because every mutator and reader is a MainActor UI path (the
/// `.task` discovery loop and the SwiftUI switcher menus); state lives where its
/// callers live, so an actor would only manufacture suspension points inside what
/// are single-turn updates today.
///
/// `String(localized:)` is resolved app-side and passed in (`loadFailureText`):
/// inside this package bundle the key would miss the app's localized catalog and
/// silently drop non-English translations.
@MainActor
@Observable
public final class CMUXSidebarExtensionSelectionModel {
    /// `UserDefaults` key the chosen extension's bundle identifier is stored under.
    public static let selectedExtensionBundleIDDefaultsKey = "cmuxExtensionSidebar.selectedExtensionBundleId"

    /// The currently hosted extension identity, or `nil` when none is selected or available.
    public private(set) var identity: AppExtensionIdentity?
    /// The deduplicated, name-sorted set of enabled sidebar-extension identities.
    public private(set) var enabledIdentities: [AppExtensionIdentity] = []
    /// Whether the initial identity discovery is still in flight.
    public private(set) var isLoading = true
    /// User-facing error text for the empty state, or `nil` when there is no error.
    /// Settable so the view can surface an XPC deactivation error directly.
    public var errorText: String?
    /// Count of installed sidebar extensions that are disabled.
    public private(set) var disabledExtensionCount = 0
    /// Count of installed sidebar extensions that still need approval.
    public private(set) var unapprovedExtensionCount = 0

    /// Bundle identifier of the user's chosen extension, seeded from `defaults`.
    private var selectedExtensionBundleID: String?
    /// The `UserDefaults` suite the persisted selection is read from and written to.
    private let defaults: UserDefaults

    /// Creates a selection model, seeding the chosen bundle identifier from `defaults`.
    /// - Parameter defaults: Suite to read/write the persisted selection. Defaults to
    ///   `.standard`, the live suite the settings store persists to.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedExtensionBundleID = defaults.string(
            forKey: Self.selectedExtensionBundleIDDefaultsKey
        )
    }

    /// Discovers and continuously observes enabled sidebar-extension identities,
    /// updating `identity`, `enabledIdentities`, and the availability counts as the
    /// system reports changes. On failure, clears the selection and sets `errorText`.
    ///
    /// - Parameters:
    ///   - loadFailureText: App-bundle-localized error string shown when discovery throws.
    ///   - onSelectedIdentityChange: Invoked on the main actor immediately before the
    ///     hosted identity changes, so the view can tear down the stale XPC host and
    ///     clear its effective grant.
    ///   - onLoadFailure: Invoked on the main actor when discovery throws, so the view
    ///     can tear down the host and clear blocked-manifest state.
    public func observeExtensionAvailability(
        loadFailureText: String,
        onSelectedIdentityChange: () -> Void,
        onLoadFailure: () -> Void
    ) async {
        isLoading = true
        errorText = nil
        do {
            try await observeIdentitySequence(
                extensionPointIdentifier: CmuxSidebarExtensionPoint.identifier(),
                onSelectedIdentityChange: onSelectedIdentityChange
            )
        } catch {
            identity = nil
            onLoadFailure()
            isLoading = false
            errorText = loadFailureText
        }
    }

    /// Selects `selectedIdentity`, persisting it as the chosen extension and
    /// re-resolving the hosted identity from the current enabled set.
    /// - Parameters:
    ///   - selectedIdentity: The identity the user chose.
    ///   - onSelectedIdentityChange: Invoked before the hosted identity changes.
    public func selectExtension(
        _ selectedIdentity: AppExtensionIdentity,
        onSelectedIdentityChange: () -> Void
    ) {
        selectedExtensionBundleID = selectedIdentity.bundleIdentifier
        defaults.set(selectedIdentity.bundleIdentifier, forKey: Self.selectedExtensionBundleIDDefaultsKey)
        defaults.set(selectedIdentity.localizedName, forKey: CmuxExtensionSidebarSelection.selectedExtensionNameDefaultsKey)
        applyEnabledExtensionIdentities(enabledIdentities, onSelectedIdentityChange: onSelectedIdentityChange)
    }

    private func observeIdentitySequence(
        extensionPointIdentifier: String,
        onSelectedIdentityChange: () -> Void
    ) async throws {
        var identities = try AppExtensionIdentity.matching(appExtensionPointIDs: extensionPointIdentifier)
            .makeAsyncIterator()
        let availabilityTask = Task {
            var availabilityUpdates = AppExtensionIdentity.availabilityUpdates.makeAsyncIterator()
            while !Task.isCancelled {
                guard let availability = await availabilityUpdates.next() else { break }
                disabledExtensionCount = availability.disabledCount
                unapprovedExtensionCount = availability.unapprovedCount
            }
        }
        defer {
            availabilityTask.cancel()
        }
        while !Task.isCancelled {
            guard let update = await identities.next() else { break }
            applyEnabledExtensionIdentities(update, onSelectedIdentityChange: onSelectedIdentityChange)
        }
    }

    private func applyEnabledExtensionIdentities(
        _ identities: [AppExtensionIdentity],
        onSelectedIdentityChange: () -> Void
    ) {
        let sortedIdentities = deduplicatedExtensionIdentities(identities)
        enabledIdentities = sortedIdentities
        let nextIdentity: AppExtensionIdentity?
        if let selectedExtensionBundleID,
           let selectedIdentity = sortedIdentities.first(where: { $0.bundleIdentifier == selectedExtensionBundleID }) {
            nextIdentity = selectedIdentity
        } else if selectedExtensionBundleID == nil, sortedIdentities.count == 1 {
            nextIdentity = sortedIdentities[0]
            selectedExtensionBundleID = nextIdentity?.bundleIdentifier
            defaults.set(nextIdentity?.bundleIdentifier, forKey: Self.selectedExtensionBundleIDDefaultsKey)
        } else {
            nextIdentity = nil
        }
        updateSelectedExtensionName(nextIdentity)
        if nextIdentity?.bundleIdentifier != identity?.bundleIdentifier {
            onSelectedIdentityChange()
            identity = nextIdentity
        }
        isLoading = false
        errorText = nil
    }

    private func deduplicatedExtensionIdentities(_ identities: [AppExtensionIdentity]) -> [AppExtensionIdentity] {
        let sortedIdentities = identities.sorted {
            if $0.localizedName == $1.localizedName {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.localizedName < $1.localizedName
        }
        var seenBundleIdentifiers = Set<String>()
        return sortedIdentities.filter { identity in
            seenBundleIdentifiers.insert(identity.bundleIdentifier).inserted
        }
    }

    private func updateSelectedExtensionName(_ selectedIdentity: AppExtensionIdentity?) {
        if let selectedIdentity {
            defaults.set(selectedIdentity.localizedName, forKey: CmuxExtensionSidebarSelection.selectedExtensionNameDefaultsKey)
        } else if selectedExtensionBundleID == nil {
            defaults.removeObject(forKey: CmuxExtensionSidebarSelection.selectedExtensionNameDefaultsKey)
        }
    }
}
