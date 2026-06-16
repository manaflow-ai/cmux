import CMUXAgentLaunch
import Foundation

struct AmpHookLaunchCommandRecord: Decodable {
    var launcher: String?
    var executablePath: String?
    var arguments: [String]?
    var workingDirectory: String?
    var environment: [String: String]?
    var capturedAt: TimeInterval?
    var source: String?

    var snapshot: AgentLaunchCommandSnapshot? {
        guard launcher != nil || executablePath != nil || !(arguments?.isEmpty ?? true) || !(environment?.isEmpty ?? true) else {
            return nil
        }
        return AgentLaunchCommandSnapshot(
            launcher: launcher,
            executablePath: executablePath,
            arguments: arguments ?? [],
            workingDirectory: workingDirectory,
            environment: environment,
            capturedAt: capturedAt,
            source: source
        )
    }
}
