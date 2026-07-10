@testable import CmuxSimulatorWorker

actor CameraReinjectionSimctlFake {
    private let bundleIdentifier: String
    private let processIdentifier: Int32
    private var invocations: [([String], [String: String])] = []

    init(bundleIdentifier: String, processIdentifier: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    func run(
        arguments: [String],
        environment: [String: String]
    ) -> SimulatorSubprocessResult {
        invocations.append((arguments, environment))
        if arguments.first == "listapps" {
            return SimulatorSubprocessResult(
                status: 0,
                standardOutput: """
                {
                    "\(bundleIdentifier)" = {
                        ApplicationType = User;
                        Path = "/tmp/CameraFixture.app";
                    };
                }
                """,
                standardError: ""
            )
        }
        if arguments.first == "launch",
           environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] != nil {
            return SimulatorSubprocessResult(
                status: 0,
                standardOutput: "\(bundleIdentifier): \(processIdentifier)\n",
                standardError: ""
            )
        }
        return SimulatorSubprocessResult(status: 0, standardOutput: "", standardError: "")
    }

    var injectedLaunchCount: Int {
        invocations.count {
            $0.0.first == "launch"
                && $0.1["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] != nil
        }
    }

    var lifecycleMutationCount: Int {
        invocations.count {
            $0.0.first == "terminate" || $0.0.first == "launch"
        }
    }
}
