import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// LAUNCH-NO-TCC-PROMPTS: the claude.ai and ChatGPT export zips sit in ~/Downloads and ~/Desktop, which macOS
/// guards. Only the person's own Import Memories run lists them; the launch-time offer, a script, the CLI, an
/// agent or a run the control socket carries lists only the agents' own folders.
@MainActor @Suite struct ChiefMemoryImportExportsTests {
    private let muxHome = "/h/mux"

    @Test func theLaunchTimeOfferNeverListsTheExportZips() {
        let arguments = ChiefMemoryImportHandlers.offerDetectArguments(muxHome: muxHome)
        #expect(arguments.starts(with: ["memory", "import-from", "detect", "--json"]))
        #expect(!arguments.contains("--exports"))
    }

    @Test func onlyThePersonsOwnRunListsTheExportZips() {
        let person = ChiefMemoryImportHandlers.detectArguments(muxHome: muxHome, invocation: ActionInvocation(origin: .user))
        #expect(person.contains("--exports"))

        for origin in ActionOrigin.allCases where origin != .user {
            let arguments = ChiefMemoryImportHandlers.detectArguments(muxHome: muxHome, invocation: ActionInvocation(origin: origin))
            #expect(!arguments.contains("--exports"), "\(origin)")
        }
        // A socket run that claims the person's origin is still automation.
        var claimed = ActionInvocation(origin: .user)
        claimed.viaControlSocket = true
        #expect(!ChiefMemoryImportHandlers.detectArguments(muxHome: muxHome, invocation: claimed).contains("--exports"))
        // So is a run that names a caller (an app, an agent chat or a terminal), even during the person's gesture in it.
        var app = ActionInvocation(origin: .user)
        app.callerApp = "com.example.app"
        var chat = ActionInvocation(origin: .user)
        chat.callerAgentSession = "agent-1"
        var terminal = ActionInvocation(origin: .user)
        terminal.callerTerminal = "terminal-1"
        for caller in [app, chat, terminal] {
            #expect(!ChiefMemoryImportHandlers.detectArguments(muxHome: muxHome, invocation: caller).contains("--exports"))
        }
    }
}
