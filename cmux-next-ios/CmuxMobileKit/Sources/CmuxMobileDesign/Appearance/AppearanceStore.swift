#if os(iOS)
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

private let log = Logger(subsystem: "dev.cmux.mobile", category: "appearance")

/// The look the phone draws right now (PROTOCOL.md "Appearance"): the built-in
/// neutral look, or a Mac's theme, background and accents. Every color token
/// reads it (``CmuxMobileColors``, `Color.cmuxMobile…`, `UIColor.cmuxMobile…`,
/// the terminal), so chat, terminal, sidebar, tab grid and composer change
/// together, in one transaction.
///
/// Loaded synchronously at launch from the last stored snapshot
/// (``loadAtLaunch()``), before the first frame, so a themed phone never
/// flashes the neutral look. Written on the main thread only; read anywhere
/// (UIKit resolves dynamic colors on the main thread too).
@Observable
public final class CmuxMobileAppearance: @unchecked Sendable {
    public static let shared = CmuxMobileAppearance()

    /// The resolved look; nil is the neutral look.
    public private(set) var resolved: CmuxMobileResolvedAppearance?
    /// Grows with every applied change (the UIKit trait that re-resolves colors).
    public private(set) var revision = 0
    /// Where the look comes from (Settings names it).
    public private(set) var source: Source = .neutral

    public enum Source: Equatable, Sendable {
        /// Never connected, or the phone's own neutral choice.
        case neutral
        /// A Mac's snapshot (its id).
        case mac(String)
        /// The phone's own Personalization choice.
        case phone
    }

    /// The phone's own Accent color choice (the neutral look's accent).
    @ObservationIgnored private let accentTheme: CmuxMobileAccentTheme
    /// Snapshots and images on disk.
    @ObservationIgnored public let disk: CmuxMobileAppearanceDisk
    /// Called after every applied change, on the main thread (the terminal's
    /// Ghostty config, the UIKit trait). Keyed so a registrant replaces itself.
    @ObservationIgnored private var observers: [String: @MainActor (CmuxMobileAppearance) -> Void] = [:]

    public init(accentTheme: CmuxMobileAccentTheme = .shared, disk: CmuxMobileAppearanceDisk = .standard) {
        self.accentTheme = accentTheme
        self.disk = disk
    }

    /// One role's value in the current look. In the neutral look the accent is
    /// the phone's Accent color choice.
    public func token(_ role: CmuxMobileColorRole) -> CmuxMobileColorToken {
        if let resolved { return resolved.palette[role] }
        switch role {
        case .accent: return accentTheme.accent.accent
        case .onAccent: return accentTheme.accent.onAccent
        default: return CmuxMobilePaletteValues.neutral[role]
        }
    }

    public var terminal: CmuxMobileTerminalTheme { resolved?.terminal ?? .neutral }
    public var backdrop: CmuxMobileBackdropStyle? { resolved?.backdrop }
    public var colorScheme: ColorScheme? { resolved?.colorScheme }
    public var isThemed: Bool { resolved != nil }

    /// Applies `look` (nil: neutral) from `source`, at once; observers run after.
    @MainActor
    public func apply(_ look: CmuxMobileResolvedAppearance?, source: Source) {
        guard look != resolved || source != self.source else { return }
        resolved = look
        self.source = source
        revision += 1
        for observer in observers.values { observer(self) }
    }

    /// Calls `body` after every change (and never for the current look).
    @MainActor
    public func observe(_ key: String, _ body: @escaping @MainActor (CmuxMobileAppearance) -> Void) {
        observers[key] = body
    }

    // MARK: - Choosing the look

    /// The look the phone should draw from what it has stored: the phone's
    /// own Personalization choice (``CmuxMobilePersonalization``) when it is
    /// not "Match my Mac", else the snapshot of the Mac most recently
    /// connected. Synchronous: it runs before the first frame.
    public func storedLook() -> (CmuxMobileResolvedAppearance?, Source) {
        let choice = disk.personalization
        if choice.mode == .phone {
            guard let snapshot = choice.snapshot() else { return (nil, .phone) }
            let url = choice.background.flatMap { disk.phoneImageURL(sha256: $0) }
            return (CmuxMobileAppearanceResolver.resolve(snapshot, backgroundURL: url), .phone)
        }
        if let macID = disk.lastMacID, let snapshot = disk.snapshot(macID: macID) {
            let url = snapshot.background.flatMap { disk.assetURL(sha256: $0.sha256) }
            if let look = CmuxMobileAppearanceResolver.resolve(snapshot, backgroundURL: url) {
                return (look, .mac(macID))
            }
        }
        return (nil, .neutral)
    }

    /// Loads the stored look before the first frame (`App.init`).
    @MainActor
    public func loadAtLaunch() {
        let started = ContinuousClock.now
        #if DEBUG
        if let fixture = CmuxMobileAppearanceFixture.requested() {
            fixture.install(into: disk)
        }
        #endif
        let (look, source) = storedLook()
        apply(look, source: source)
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        log.info("appearance at launch: \(String(describing: source), privacy: .public) in \(ms, format: .fixed(precision: 1)) ms")
    }

    /// The phone's own Personalization choice; applied at once (it overrides
    /// every Mac's look until it is "Match my Mac" again).
    @MainActor
    public var personalization: CmuxMobilePersonalization {
        get { disk.personalization }
        set {
            disk.personalization = newValue
            let (look, source) = storedLook()
            apply(look, source: source)
        }
    }

    /// A Mac's snapshot was stored: the look applies when that Mac is the
    /// one the phone matches.
    @MainActor
    public func macSnapshotChanged(macID: String) {
        guard disk.lastMacID == macID, disk.personalization.mode == .matchMac else { return }
        let (look, source) = storedLook()
        apply(look, source: source)
    }
}

/// A UIKit trait whose value is the appearance's revision: set on each window,
/// so a theme change re-resolves every dynamic color UIKit holds (a layer's
/// background, a label's text color) as a Light/Dark change does.
public struct CmuxMobileAppearanceRevisionTrait: UITraitDefinition {
    public static let defaultValue = 0
    public static let affectsColorAppearance = true
    public static let name = "CmuxMobileAppearanceRevision"
}

extension View {
    /// The app root's appearance: the scheme a fixed theme holds, the window
    /// trait that re-resolves UIKit colors, and the backdrop under everything.
    public func cmuxMobileAppearanceRoot() -> some View {
        modifier(AppearanceRoot())
    }
}

private struct AppearanceRoot: ViewModifier {
    private let appearance = CmuxMobileAppearance.shared

    func body(content: Content) -> some View {
        content
            .background { CmuxMobileBackdrop().ignoresSafeArea() }
            .background { AppearanceWindowTrait(revision: appearance.revision, scheme: appearance.colorScheme).frame(width: 0, height: 0) }
    }
}

/// Sets ``CmuxMobileAppearanceRevisionTrait`` on its window, and a theme's
/// fixed scheme on a window that follows the system (the app's own
/// Light/Dark setting, when set, is the window's override and stays).
private struct AppearanceWindowTrait: UIViewRepresentable {
    let revision: Int
    let scheme: ColorScheme?

    func makeUIView(context: Context) -> TraitView { TraitView() }

    func updateUIView(_ view: TraitView, context: Context) {
        view.revision = revision
        view.scheme = scheme
        view.push()
    }

    final class TraitView: UIView {
        var revision = 0
        var scheme: ColorScheme?
        /// The style this view set (so it only ever replaces its own).
        private var applied: UIUserInterfaceStyle?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            push()
        }

        func push() {
            guard let window else { return }
            // Reading an override that was never set throws: compare the window's resolved trait.
            if window.traitCollection[CmuxMobileAppearanceRevisionTrait.self] != revision
                || !window.traitOverrides.contains(CmuxMobileAppearanceRevisionTrait.self) {
                window.traitOverrides[CmuxMobileAppearanceRevisionTrait.self] = revision
            }
            let style: UIUserInterfaceStyle = switch scheme {
            case .dark?: .dark
            case .light?: .light
            default: .unspecified
            }
            if window.overrideUserInterfaceStyle == .unspecified || window.overrideUserInterfaceStyle == applied {
                window.overrideUserInterfaceStyle = style
                applied = style
            }
        }
    }
}
#endif
