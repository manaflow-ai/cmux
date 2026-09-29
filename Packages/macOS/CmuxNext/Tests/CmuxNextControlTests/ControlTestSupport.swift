import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Synchronization

/// Records every request and answers with a fixed outcome.
final class RecordingExecutor: ControlActionExecutor {
    let requests = Mutex<[ControlActionRequest]>([])
    let outcome: ControlActionOutcome

    init(outcome: ControlActionOutcome = .ran) {
        self.outcome = outcome
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        requests.withLock { $0.append(request) }
        return outcome
    }

    var last: ControlActionRequest? { requests.withLock { $0.last } }
}

/// A blocking line client, like the `cmux` CLI's socket client.
final class LineClient {
    let descriptor: Int32

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(descriptor) }

    /// Sends one line and reads one response line ("" on EOF).
    func send(_ line: String) -> String {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        return readLine()
    }

    func readLine() -> String {
        var result: [UInt8] = []
        var byte: UInt8 = 0
        while read(descriptor, &byte, 1) == 1 {
            if byte == 0x0A { break }
            result.append(byte)
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Sends a v2 request and decodes the response object.
    func call(_ method: String, _ params: JSONValue = [:]) throws -> JSONValue {
        let request: JSONValue = ["id": "t1", "method": .string(method), "params": params]
        return try JSONValue.parse(Data(send(request.compactText).utf8))
    }
}

func temporarySocketPath() -> String {
    "/tmp/cnc-\(UUID().uuidString.prefix(8).lowercased()).sock"
}

func testIdentity() -> ControlIdentity {
    ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test", processID: getpid())
}

/// A small catalog for router tests.
func sampleCatalog(contextMask: UInt32 = 0) -> ControlCatalog {
    let color = ControlArgumentInfo(
        name: "color", title: "Color", kind: .enumeration, isRequired: false,
        choices: ["grey", "green"].map { ControlArgumentInfo.Choice(value: $0, title: $0.capitalized) }
    )
    return ControlCatalog(
        actions: [
            ControlActionInfo(
                id: "tabGroup.create", title: "New Tab Group", category: "tab", categoryTitle: "Tabs",
                cliName: "tab-group create", symbol: "plus", keywords: [], shortcut: nil, shortcutConfig: nil,
                arguments: [ControlArgumentInfo(name: "name", title: "Name", kind: .string, isRequired: false), color],
                targets: ["tab"], requiresMask: 0, requires: [], isBound: true, isDebugOnly: false, mainMenu: nil
            ),
            ControlActionInfo(
                id: "selectWorkspaceByNumber", title: "Select Workspace", category: "workspace", categoryTitle: "Workspace",
                cliName: "workspace select-number", symbol: "number", keywords: [], shortcut: "⌘1…9", shortcutConfig: "cmd+1",
                arguments: [ControlArgumentInfo(name: "index", title: "Number", kind: .int, isRequired: true, range: 1...9)],
                targets: [], requiresMask: 0, requires: [], isBound: true, isDebugOnly: false, mainMenu: nil
            ),
            ControlActionInfo(
                id: "workspaceGroup.collapse", title: "Collapse Group", category: "workspace", categoryTitle: "Workspace",
                cliName: "workspace-group collapse", symbol: "chevron.right", keywords: [], shortcut: nil, shortcutConfig: nil,
                arguments: [], targets: ["workspace-group"], requiresMask: 0, requires: [], isBound: true, isDebugOnly: false, mainMenu: nil
            ),
            ControlActionInfo(
                id: "browserReload", title: "Reload Page", category: "browser", categoryTitle: "Browser",
                cliName: "browser reload", symbol: "arrow.clockwise", keywords: [], shortcut: "⌘R", shortcutConfig: "cmd+r",
                arguments: [], targets: [], requiresMask: 2, requires: ["browserFocused"], isBound: true, isDebugOnly: false, mainMenu: nil
            ),
        ],
        contextMask: contextMask,
        aliases: ["tab.group.new": "tabGroup.create"],
        targetKinds: ["tab", "tab-group", "pane", "column", "screen", "workspace", "workspace-group", "window"],
        debugActionsAvailable: true
    )
}
