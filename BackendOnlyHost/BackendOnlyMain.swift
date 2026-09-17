import CmuxTerminalBackendHost
import Darwin
import Foundation

@main
enum CmuxBackendOnlyMain {
    @MainActor
    static func main() async {
        let maintenance = BackendOnlyServiceMaintenanceRunner(
            userID: UInt32(Darwin.geteuid()),
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
        if let status = await maintenance.run() {
            Darwin.exit(status)
        }
        TerminalBackendHostApplication.main()
    }
}
