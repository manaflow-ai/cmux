import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator worker entrypoint")
struct CmuxSimulatorWorkerNamespaceTests {
    @Test("DEVELOPER_DIR wins over xcode-select")
    func developerDirectoryOverride() {
        let directory = SimulatorDeveloperDirectoryResolver().resolve(
            environment: ["DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"]
        )

        #expect(directory == "/Applications/Xcode-beta.app/Contents/Developer")
    }
}
