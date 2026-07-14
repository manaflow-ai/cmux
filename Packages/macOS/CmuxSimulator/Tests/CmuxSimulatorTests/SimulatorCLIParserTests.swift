import Testing
@testable import CmuxSimulator

@Suite("SimulatorCLIParser")
struct SimulatorCLIParserTests {
    private let parser = SimulatorCLIParser()

    @Test func emptyAndHelpTokensParseAsHelp() throws {
        #expect(try parser.parse([]) == .help)
        #expect(try parser.parse(["--help"]) == .help)
        #expect(try parser.parse(["-h"]) == .help)
        #expect(try parser.parse(["help"]) == .help)
        #expect(try parser.parse(["open", "--help"]) == .help)
    }

    @Test func listParses() throws {
        #expect(try parser.parse(["list"]) == .list)
        #expect(try parser.parse(["ls"]) == .list)
        #expect(try parser.parse(["list", "--json"]) == .list)
    }

    @Test func openRequiresDevice() {
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["open"])
        }
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["open", "--device", "   "])
        }
    }

    @Test func openParsesDeviceWorkspaceWindowAndFocus() throws {
        let request = try parser.parse([
            "open",
            "--device", "iPhone 17 Pro",
            "--workspace", "workspace:2",
            "--window", "window:1",
            "--focus", "true",
        ])
        #expect(request == .open(SimulatorCLIOpenRequest(
            deviceQuery: "iPhone 17 Pro",
            workspace: "workspace:2",
            window: "window:1",
            focus: true
        )))
    }

    @Test func openDefaultsToNoFocus() throws {
        let request = try parser.parse(["open", "--device", "iPhone 17 Pro"])
        guard case .open(let open) = request else {
            Issue.record("expected open request")
            return
        }
        #expect(open.focus == false)
        #expect(open.workspace == nil)
        #expect(open.window == nil)
    }

    @Test func focusRejectsNonBooleanValues() {
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["open", "--device", "x", "--focus", "maybe"])
        }
    }

    @Test func closeParsesOptionalHandles() throws {
        #expect(try parser.parse(["close"]) == .close(SimulatorCLICloseRequest()))
        let request = try parser.parse(["close", "--surface", "surface:3", "--workspace", "workspace:2"])
        #expect(request == .close(SimulatorCLICloseRequest(
            surface: "surface:3",
            workspace: "workspace:2",
            window: nil
        )))
    }

    @Test func unknownTokensAreLoudErrors() {
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["reboot"])
        }
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["open", "--device", "x", "--frobnicate", "y"])
        }
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["list", "extra"])
        }
        // A flag valid elsewhere in the namespace is rejected on the wrong verb.
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["close", "--device", "x"])
        }
        // A dangling flag with no value is an error, not a silent skip.
        #expect(throws: SimulatorCLIParseError.self) {
            _ = try parser.parse(["open", "--device"])
        }
    }
}
