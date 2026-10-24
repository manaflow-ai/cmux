import AppKit
@testable import CmuxNextApps
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// Production app components over two same-tree native daemons and one actual acpmux daemon.
/// Every process gets a private HOME, config, state and socket. No harness or network fetch runs.
@MainActor
final class MachineCatalogAppFixture {
    let root: URL
    let binary: URL
    let local = DaemonService()
    let package = MachineCatalogAppPackage()
    lazy var registry = MachineRegistry(local: local)
    var server: ServerMachineSession?
    var transport: DaemonAppsTransport?
    var publisher: MachineCatalogPublisher?
    private var controls: [DaemonConnection] = []
    private var acpEnvironment: [String: String]?

    init(binary: URL) throws {
        self.binary = binary
        root = URL(fileURLWithPath: "/private/tmp/cn-appcat-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func start() async throws {
        _ = NSApplication.shared
        let appRoot = root.appendingPathComponent("apps/inventory")
        try package.write(to: appRoot)
        let key = FrontendInstallKey.generate()
        var localEnvironment = try environment("local")
        localEnvironment["CMUX_APPS_DIRS"] = appRoot.deletingLastPathComponent().path
        localEnvironment["CMUX_APPS_DEFAULT"] = ""
        let localLauncher = launcher("local", environment: localEnvironment, installKey: key)
        let localEndpoint = try await startOwner(localLauncher)
        local.start {
            DaemonConnection(endpoint: localEndpoint, configuration: .init(terminalEnvironment: nil, clientHello: .init(installKey: key)))
        }
        try await wait("local app owner") { self.local.connection != nil && self.local.identity != nil }
        let localConnection = try #require(local.connection)
        #expect(await localConnection.userOriginAllowed)
        try #require(local.identity?.supports("apps-v1") == true, "same-tree app host must be available")

        let remoteEnvironment = try environment("server")
        let started = try await command(["acp", "daemon", "start", "--json"], environment: remoteEnvironment)
        acpEnvironment = remoteEnvironment
        try #require(started["pid"] != nil, "acpmux start must report its actual daemon")
        let remoteLauncher = launcher("server", environment: remoteEnvironment)
        let remoteEndpoint = try await startOwner(remoteLauncher)
        let reach = try ServerReach(hostID: "host_catalogapp01", installID: "inst_catalogapp01", name: "Isolated server", route: .unix(remoteEndpoint.socketPath))
        let server = ServerMachineSession(reach: reach, binary: nil, paths: .init(root: root.appendingPathComponent("links")),
                                          environment: { remoteEnvironment }, localIdentity: { [local] in local.identity },
                                          mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        self.server = server
        registry.add(server)
        server.connect()
        try await wait("server registry handshake") { server.daemon.connection != nil && server.daemon.identity != nil }

        let transport = DaemonAppsTransport(daemon: local, inventoryRoutes: { [registry] in registry.agentInventoryWatchRoutes() })
        self.transport = transport
        transport.provider.attach(AppHostCapabilities([AgentCLICapabilityHandler { [registry] in registry.agentInventoryRoutes() }]))
        transport.start()
        try await wait("native provider registration") { transport.provider.isRegistered }
        let publisher = MachineCatalogPublisher { [registry] in registry.catalogSource() }
        self.publisher = publisher
        publisher.start()
        try await wait("native catalog acknowledgement") { publisher.publishedSequence != nil }
        _ = try await localConnection.request(AppsSetRequest(idempotencyKey: UUID().uuidString, app: package.id, origin: "user", installed: true))
    }

    func run(_ verb: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        let connection = try #require(local.connection)
        do {
            return try await connection.request(AppsRunRequest(app: package.id, op: "\(package.family).\(verb)",
                                                                args: .object(params), idempotencyKey: nil, origin: .script), timeout: .seconds(20)).value
        } catch let DaemonError.command(command, message, code, details, retryable) {
            guard code == "apps.host" else { throw DaemonError.command(cmd: command, message: message, code: code, details: details, retryable: retryable) }
            let logs = try? await connection.request(AppsLogsRequest(app: package.id, follow: false))
            throw DaemonError.command(cmd: command, message: "\(verb): \(message); owned app logs: \(String(describing: logs))", code: code)
        }
    }

    func grantInventory(_ allowed: Bool) async throws {
        let connection = try #require(local.connection)
        _ = try await connection.request(AppsSetRequest(idempotencyKey: UUID().uuidString, app: package.id, origin: "user",
                                                        grant: .init(scope: "agent_cli:read", granted: allowed)))
    }

    func stop() async {
        publisher?.stop()
        publisher = nil
        transport?.provider.connectionChanged(epoch: nil)
        transport?.inventory.stop()
        transport = nil
        server?.close()
        local.shutdownConnection()
        for control in controls {
            let ended = await control.endSessionsAndStop()
            #expect(ended.failures.isEmpty, "owned native owner did not shut down: \(ended.failures)")
        }
        controls.removeAll()
        if let environment = acpEnvironment {
            do {
                let stopped = try await command(["acp", "daemon", "shutdown", "--end-agents", "--json"], environment: environment)
                #expect(stopped["stopped"] == .bool(true))
                #expect(stopped["agentHosts"]?["left"] == .array([]))
            } catch { Issue.record("owned acpmux did not shut down: \(error)") }
        }
        try? FileManager.default.removeItem(at: root)
    }

    func wait(_ name: String, _ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
        await ObservationDeadline(owner: "MachineCatalogAppFixture.\(name)").until(condition, limit: .seconds(20))
        try #require(condition(), "\(name)")
    }

    private func environment(_ name: String) throws -> [String: String] {
        let home = root.appendingPathComponent(name)
        let acp = home.appendingPathComponent("acpmux")
        try FileManager.default.createDirectory(at: acp, withIntermediateDirectories: true)
        try Data("{\"harnesses\":{}}".utf8).write(to: acp.appendingPathComponent("config.json"))
        return ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "ACPMUX_HOME": acp.path,
                "ACPMUX_SOCKET": home.appendingPathComponent("acp.sock").path, "ACPMUX_LOGIN_ENV": "0",
                "ACPMUX_CATALOG_FETCH": "0", "ACPMUX_REGISTRY_FETCH": "0", "ACPMUX_HEALTH_FETCH": "0",
                "ACPMUX_PROBE_HARNESSES": "", "ACPMUX_AGENT_HOSTS": "0"]
    }

    private func launcher(_ name: String, environment: [String: String], installKey: FrontendInstallKey? = nil) -> DaemonLauncher {
        var configuration = DaemonLauncher.Configuration(binary: binary, session: "appcat-\(name)-\(root.lastPathComponent.suffix(8))",
                                                         stateDirectory: root.appendingPathComponent("\(name)-state"), installKey: installKey)
        configuration.runtimeBase = root.appendingPathComponent("run")
        return DaemonLauncher(configuration: configuration, environment: { environment })
    }

    private func startOwner(_ launcher: DaemonLauncher) async throws -> DaemonEndpoint {
        let ensured = try await launcher.ensure()
        let control = DaemonConnection(endpoint: ensured.endpoint)
        controls.append(control)
        _ = try await control.start()
        return ensured.endpoint
    }

    private func command(_ arguments: [String], environment: [String: String]) async throws -> JSONValue {
        let output = root.appendingPathComponent("command-\(UUID().uuidString).json")
        let errors = output.appendingPathExtension("err")
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errors.path, contents: nil)
        let file = try FileHandle(forWritingTo: output)
        let errorFile = try FileHandle(forWritingTo: errors)
        defer { try? file.close(); try? errorFile.close() }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = file
        process.standardError = errorFile
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: (try Data(contentsOf: errors)).prefix(4096), as: UTF8.self)
            throw DaemonError.launchFailed("owned acpmux \(arguments) exited \(process.terminationStatus): \(detail)")
        }
        let data = try Data(contentsOf: output)
        guard data.count <= 128 * 1024 else { throw DaemonError.malformedResponse("oversized acpmux status") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
