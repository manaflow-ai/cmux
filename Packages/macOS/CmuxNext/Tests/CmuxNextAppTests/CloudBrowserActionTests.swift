import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// `cmux cloud open-browser`, `port-list`, `port-forward`, `port-close` and `machine-link`
/// (audit group H): the route a CLI run opens is checked like the Cloud page's, and every
/// failure names the machine and the port and gives the next command.
@MainActor @Suite(.serialized)
struct CloudBrowserActionTests {
    static func fixture() -> (services: AppServices, session: CloudMachineSession) {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let session = MachineIconTests.cloudMachine(services, id: "vm-port-\(UUID().uuidString.prefix(8))")
        return (services, session)
    }

    static func invocation(_ session: CloudMachineSession, _ arguments: [String: ActionValue] = [:], origin: ActionOrigin = .cli) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID), arguments: arguments, origin: origin)
    }

    /// The refusal a direct run of `id` reports.
    static func refusal(_ services: AppServices, _ id: ActionID, _ invocation: ActionInvocation) throws -> String? {
        let invoke = try #require(services.registry.action(for: id)?.invoke, "\(id) is not bound")
        return services.registry.capturingRefusal { invoke(invocation) }
    }

    static func route(url: String = "http://localhost:3000/docs", password: String = String(repeating: "b", count: 64)) -> CmuxNextDaemon.JSONValue {
        .object([
            "machine": .string("vm-alpha01"), "url": .string(url), "incarnation": .number(3), "generation": .number(9),
            "proxy": .object(["kind": .string("http"), "host": .string("127.0.0.1"), "port": .number(41_000),
                              "username": .string("cmux"), "password": .string(password)]),
        ])
    }

    @Test func everyPortActionIsACLIVerbWithAResult() throws {
        let services = Self.fixture().services
        for (id, verb) in [("cloudOpenBrowser", "cloud open-browser"), ("cloudPortList", "cloud port-list"),
                           ("cloudPortForward", "cloud port-forward"), ("cloudPortClose", "cloud port-close"),
                           ("cloudMachineLink", "cloud machine-link")] {
            let descriptor = try #require(services.registry.descriptor(for: ActionID(rawValue: id)))
            #expect(descriptor.cliName == verb)
            #expect(descriptor.cli, "\(id) is not CLI-offered")
            #expect(descriptor.surfacePlan.mcp?.isOffered == true, "\(id) is not an MCP tool")
            #expect(descriptor.waitsForResult, "\(id) answers nothing to the CLI")
            #expect(descriptor.targets == [.machine])
        }
    }

    // MARK: The route a CLI run opens

    @Test func aBrowserRouteTheAppAskedForOpensWithoutThePageCheck() throws {
        let request = try BrowserTabOpen.request(route: pageJSON(Self.route()), machineName: "alpha")
        #expect(request.url.absoluteString == "http://localhost:3000/docs")
        #expect(request.machine == "vm-alpha01")
        #expect(request.machineName == "alpha")
        #expect(request.proxyPort == 41_000)
        #expect(request.incarnation == 3 && request.generation == 9)
    }

    @Test func aRouteWithoutItsCredentialOrToAnotherHostIsRefused() {
        #expect(throws: BrowserTabOpen.Refusal.proxyInvalid) {
            try BrowserTabOpen.request(route: pageJSON(Self.route(password: "short")), machineName: "alpha")
        }
        #expect(throws: BrowserTabOpen.Refusal.invalidURL) {
            try BrowserTabOpen.request(route: pageJSON(Self.route(url: "https://example.com/")), machineName: "alpha")
        }
    }

    @Test func thePathDefaultsToTheRootAndMustBeAPath() throws {
        let f = Self.fixture()
        #expect(try CloudHandlers.browserPath(Self.invocation(f.session)) == "/")
        #expect(try CloudHandlers.browserPath(Self.invocation(f.session, ["path": .string("/docs?x=1")])) == "/docs?x=1")
        for bad in ["docs", "/a b", "/a\u{7}b"] {
            #expect(throws: ActionFailure(message: CloudPortStrings.pathInvalid)) {
                try CloudHandlers.browserPath(Self.invocation(f.session, ["path": .string(bad)]))
            }
        }
    }

    // MARK: Failures name the machine and the port, and give the next command

    @Test(arguments: ["cloudPortList", "cloudPortForward", "cloudPortClose"])
    func aClassicLinkMachineSaysWhatToRunInstead(id: String) throws {
        let f = Self.fixture()
        let refusal = try #require(try Self.refusal(f.services, ActionID(rawValue: id), Self.invocation(f.session, ["port": .int(3000)])))
        let port = id == "cloudPortList" ? nil : 3000
        #expect(refusal == CloudPortStrings.classicLink(CloudPortNames(f.session, port: port)))
        #expect(refusal.contains(f.session.machine.title))
        #expect(refusal.contains("cmux cloud open-browser --target machine:\(f.session.machineID) --port \(port.map(String.init) ?? "<port>")"))
    }

    @Test func aPortOutOfRangeIsRefusedBeforeAnythingRuns() throws {
        let f = Self.fixture()
        let refusal = try Self.refusal(f.services, "cloudOpenBrowser", Self.invocation(f.session, ["port": .int(70_000)]))
        #expect(refusal == CloudStrings.invalidPort)
    }

    @Test func aRefusedPortOpNamesTheMachineAndPort() {
        let names = CloudPortNames(name: "devbox-3", id: "vm-devbox3", port: 8080)
        let limit = CloudHandlers.portFailure(CloudAppOpFailure(code: "cmux.cloud.port_limit", message: "at most 16"), names)
        #expect(limit == CloudPortStrings.limit(names))
        #expect(limit.contains("cmux cloud port-close --target machine:vm-devbox3 --port 8080"))
        let other = CloudHandlers.portFailure(CloudAppOpFailure(code: "cloud.machine.not_found", message: "no such machine in this team"), names)
        #expect(other.contains("devbox-3") && other.contains("8080") && other.contains("no such machine in this team"))
        #expect(other.contains("cmux cloud machine-status --target machine:vm-devbox3"))
    }

    @Test func everyHintNamesAVerbTheCLIOffers() throws {
        let services = Self.fixture().services
        let names = CloudPortNames(name: "devbox-3", id: "vm-devbox3", port: 8080)
        let messages = [CloudPortStrings.classicLink(names), CloudPortStrings.noForward(names), CloudPortStrings.limit(names),
                        CloudPortStrings.failed(names, detail: "x"), CloudPortStrings.browserFailed(names, detail: "x"),
                        CloudPortStrings.noWindow(names), CloudPortStrings.updateMachine(names), CloudPortStrings.localhostOff(names),
                        CloudPortStrings.noLink(names)]
        let offered = Set(services.registry.descriptors.filter(\.cli).map(\.cliName))
        for message in messages {
            let verbs = message.components(separatedBy: "`cmux ").dropFirst().map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
            #expect(!verbs.isEmpty, "no command in: \(message)")
            for verb in verbs { #expect(offered.contains(verb.trimmingCharacters(in: CharacterSet(charactersIn: "`,.;:"))), "\(verb) is not a CLI verb") }
        }
    }

    // MARK: Results

    @Test func aForwardRecordAnswersItsLocalURL() {
        let fields = CloudHandlers.forwardFields(.object([
            "machine": .string("vm-a"), "port": .number(3000), "host": .string("127.0.0.1"), "localPort": .number(52_011),
            "generation": .number(1), "state": .string("up"), "reason": .null,
        ]))
        #expect(fields["machine_id"] == .string("vm-a"))
        #expect(fields["port"] == .int(3000))
        #expect(fields["local_port"] == .int(52_011))
        #expect(fields["url"] == .string("http://127.0.0.1:52011/"))
        #expect(fields["state"] == .string("up"))
        #expect(fields["reason"] == nil)
    }

    @Test func aMachineLinkWithoutAPortAnswersTheMachinesTarget() async throws {
        let f = Self.fixture()
        let invoke = try #require(f.services.registry.action(for: "cloudMachineLink")?.invoke)
        let run = f.services.registry.capturingRun { invoke(Self.invocation(f.session)) }
        let task = try #require(run.results.first, "machine-link tracked no result")
        guard case .success(let fields) = await task.value else {
            Issue.record("machine-link failed")
            return
        }
        #expect(fields["machine_id"] == .string(f.session.machineID))
        #expect(fields["target"] == .string("machine:\(f.session.machineID)"))
    }
}
