import Foundation

/// Gives managed provider processes an owner that can outlive an app crash.
struct AgentSessionOwnedProcessLauncher {
    private let supervisorExecutableURL: URL?

    init(supervisorExecutableURL: URL? = Bundle.main.url(forResource: "cmux", withExtension: nil, subdirectory: "bin")) {
        self.supervisorExecutableURL = supervisorExecutableURL
    }

    func prepare(
        plan: AgentSessionLaunchPlan,
        workingDirectory: String?,
        environment: [String: String]
    ) throws -> Process {
        guard let supervisorExecutableURL else {
            throw AgentSessionBridgeError.providerNotReady(plan.provider.displayName)
        }
        let process = Process()
        process.executableURL = supervisorExecutableURL
        process.arguments = ["__owned-process-supervisor", plan.executableURL.path] + plan.arguments
        process.environment = environment
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        }
        return process
    }
}
