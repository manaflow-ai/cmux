import Foundation
import Observation
import CmuxNextTerminal

/// The R92 diagnostics of the applied Ghostty config, kept current: read
/// again on every config change (`GhosttyRuntime.configDidChange`). The one
/// owner the socket report (`ghostty.diagnostics`) and the Settings page's
/// Ghostty group read, so both always show the same list.
@MainActor @Observable
final class GhosttyDiagnosticsModel {
    static let shared = GhosttyDiagnosticsModel()

    private(set) var diagnostics: [GhosttyConfigDiagnostic] = []
    private(set) var files: [String] = []

    @ObservationIgnored private let read: @MainActor () -> ([GhosttyConfigDiagnostic], [String])
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(read: @escaping @MainActor () -> ([GhosttyConfigDiagnostic], [String]) = {
        (GhosttyRuntime.shared.configDiagnosticsReport, GhosttyRuntime.shared.loadedConfigFiles)
    }, notifications: NotificationCenter = .default) {
        self.read = read
        refresh()
        observer = notifications.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            // crash-allow: the observer runs on the main queue (queue: .main), so the main actor holds.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Reads the applied config's diagnostics again.
    func refresh() {
        let (diagnostics, files) = read()
        if diagnostics != self.diagnostics { self.diagnostics = diagnostics }
        if files != self.files { self.files = files }
    }
}
