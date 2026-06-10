@_spi(CmuxHostTransport) import CMUXExtensionHostSupport
@_spi(CmuxHostTransport) import CmuxExtensionKit
import AppKit
import ExtensionFoundation
import SwiftUI


// MARK: - Identity Selection & Availability
extension CMUXInstalledExtensionSidebarHostView {
    func observeExtensionAvailability() async {
        isLoading = true
        errorText = nil
        do {
            try await observeIdentitySequence(
                extensionPointIdentifier: CmuxSidebarExtensionPoint.identifier()
            )
        } catch {
            identity = nil
            xpcHost.invalidate()
            blockedManifestReason = nil
            isLoading = false
            errorText = String(
                localized: "sidebar.extensions.error",
                defaultValue: "CMUX could not load sidebar extensions."
            )
        }
    }

    private func observeIdentitySequence(extensionPointIdentifier: String) async throws {
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
            applyEnabledExtensionIdentities(update)
        }
    }

    private func applyEnabledExtensionIdentities(_ identities: [AppExtensionIdentity]) {
        let sortedIdentities = deduplicatedExtensionIdentities(identities)
        enabledIdentities = sortedIdentities
        let nextIdentity: AppExtensionIdentity?
        if let selectedExtensionBundleID,
           let selectedIdentity = sortedIdentities.first(where: { $0.bundleIdentifier == selectedExtensionBundleID }) {
            nextIdentity = selectedIdentity
        } else if selectedExtensionBundleID == nil, sortedIdentities.count == 1 {
            nextIdentity = sortedIdentities[0]
            selectedExtensionBundleID = nextIdentity?.bundleIdentifier
            UserDefaults.standard.set(nextIdentity?.bundleIdentifier, forKey: Self.selectedExtensionBundleIDDefaultsKey)
        } else {
            nextIdentity = nil
        }
        updateSelectedExtensionName(nextIdentity)
        if nextIdentity?.bundleIdentifier != identity?.bundleIdentifier {
            xpcHost.invalidate()
            effectiveGrant = nil
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

    func selectExtension(_ selectedIdentity: AppExtensionIdentity) {
        selectedExtensionBundleID = selectedIdentity.bundleIdentifier
        UserDefaults.standard.set(selectedIdentity.bundleIdentifier, forKey: Self.selectedExtensionBundleIDDefaultsKey)
        UserDefaults.standard.set(selectedIdentity.localizedName, forKey: Self.selectedExtensionNameDefaultsKey)
        applyEnabledExtensionIdentities(enabledIdentities)
    }

    private func updateSelectedExtensionName(_ selectedIdentity: AppExtensionIdentity?) {
        if let selectedIdentity {
            UserDefaults.standard.set(selectedIdentity.localizedName, forKey: Self.selectedExtensionNameDefaultsKey)
        } else if selectedExtensionBundleID == nil {
            UserDefaults.standard.removeObject(forKey: Self.selectedExtensionNameDefaultsKey)
        }
    }

}
