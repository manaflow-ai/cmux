public import AppKit
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextDictation

/// Share Screen with Chief's actions (docs/chief-screen-share.md): the Home header toggle, the
/// palette, the CLI (`cmux chief share-screen | stop-sharing-screen | look-at-screen |
/// toggle-screen-share`) and MCP all run these on one ``ChiefScreenShare``. While sharing, the menu
/// bar shows ``ChiefScreenShareIndicator``; a refused Screen Recording permission says why and opens
/// its System Settings pane.
///
/// ```swift
/// ChiefScreenShareActions(share: services.chiefScreenShare, registry: registry).bind()
/// ```
@MainActor
public struct ChiefScreenShareActions {
    /// Starts sharing when off, else stops it (the header toggle).
    public static let toggleID: ActionID = "chief.screenShare.toggle"
    /// Starts sharing.
    public static let startID: ActionID = "chief.screenShare.start"
    /// Stops sharing; unavailable while off.
    public static let stopID: ActionID = "chief.screenShare.stop"
    /// Looks at the screen now and answers the frame's file and text; unavailable while off.
    public static let lookID: ActionID = "chief.screenShare.look"

    /// The Home header toggle's label and tooltip.
    public static var headerLabel: String { ChiefScreenShareStrings.headerLabel }

    private let share: ChiefScreenShare
    private let registry: ActionRegistry
    private let indicator: ChiefScreenShareIndicator
    private let openPermissionSettings: @MainActor () -> Void

    /// - Parameters:
    ///   - share: The app's one sharing model.
    ///   - registry: Where the actions are bound.
    ///   - indicator: The menu bar item; tests pass one that never shows.
    ///   - openPermissionSettings: Opens System Settings at Screen Recording; tests record it.
    public init(share: ChiefScreenShare, registry: ActionRegistry, indicator: ChiefScreenShareIndicator = ChiefScreenShareIndicator(),
                openPermissionSettings: @escaping @MainActor () -> Void = ChiefScreenShareActions.openScreenRecordingSettings) {
        self.share = share
        self.registry = registry
        self.indicator = indicator
        self.openPermissionSettings = openPermissionSettings
    }

    /// Binds the four actions and starts the watch that shows the indicator and says why a start
    /// shared nothing. The watch lives as long as `share`.
    public func bind() {
        let share = share
        let notSharing: @MainActor () -> String? = { share.isOn ? nil : ChiefScreenShareStrings.notSharing }
        registry.bindEffect(Self.toggleID) { _ in
            return .done
        }
        registry.bindEffect(Self.startID) { _ in
            share.start()
            return .done
        }
        registry.bindEffect(Self.stopID, unavailable: notSharing) { _ in
            share.stop()
            return .done
        }
        registry.bindEffect(Self.lookID, unavailable: notSharing) { _ in
            .applied(result: {
                do throws(ChiefScreenShareError) {
                    _ = try await share.look()
                    return .success([:])
                } catch {
                    return .failure(ActionWorkFailure(refusal: .unavailable, reason: ChiefScreenShareStrings.text(error)))
                }
            })
        }
        indicator.menuItem = { [weak registry] id in registry?.makeMenuItem(for: id) }
        watch()
    }

    /// What `look` answers a capturing caller (the CLI prints it, MCP returns it).
    static func fields(_ seen: ChiefScreenObservation) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = [
            "frame": .string(seen.frame), "text": .string(seen.text), "day": .string(seen.day), "time": .string(seen.time),
        ]
        if let app = seen.app { fields["app"] = .string(app) }
        if let window = seen.window { fields["window"] = .string(window) }
        return fields
    }

    private func watch() {
        let (share, registry, indicator, openSettings) = (share, registry, indicator, openPermissionSettings)
        // task-owner: the app's one sharing watch; event-driven (Observation), ends when the model goes.
        Task { @MainActor [weak share, weak registry] in
            guard let share else { return }
            var last = ChiefScreenShare.State.off
            for await state in ObservationStream({ [weak share] in share?.state ?? .off }) {
                defer { last = state }
                guard state != last else { continue }
                switch state {
                case .needsPermission:
                    registry?.refuse(ChiefScreenShareStrings.needsPermission)
                case .failed:
                    registry?.refuse(ChiefScreenShareStrings.failed)
                case .off, .starting, .sharing:
                    break
                }
            }
        }
    }

    /// System Settings > Privacy & Security > Screen & System Audio Recording, opened without
    /// waiting on Launch Services.
    public static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.openInBackground(url)
    }
}
