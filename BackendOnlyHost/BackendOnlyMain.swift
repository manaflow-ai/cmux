import CmuxTerminalBackendHost
import Darwin

@main
enum CmuxBackendOnlyMain {
    @MainActor
    static func main() async {
        if let status = await BackendOnlyServiceMaintenanceRunner().run() {
            Darwin.exit(status)
        }
        TerminalBackendHostApplication.main()
    }
}
