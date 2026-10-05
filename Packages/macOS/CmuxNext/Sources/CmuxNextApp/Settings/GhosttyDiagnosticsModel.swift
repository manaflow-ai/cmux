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

    init(read: @escaping @MainActor () -> ([GhosttyConfigDiagnostic], [String]) = {
        (GhosttyRuntime.shared.configDiagnosticsReport, GhosttyRuntime.shared.loadedConfigFiles)
    }, notifications: NotificationCenter = .default) {
        self.read = read
    }
}
