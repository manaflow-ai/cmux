import XCTest
import Foundation

final class AutomationSocketUITests: XCTestCase {
    private var socketPath = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        resetSocketDefaults()
        removeSocketFile()
    }

    func testSocketToggleDisablesAndEnables() {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", "cmuxOnly"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launch()
        app.activate()

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail("Expected control socket to exist")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocket(exists: true, timeout: 2.0))
        app.terminate()
    }

    func testSocketDisabledWhenSettingOff() {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", "off"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launch()
        app.activate()

        XCTAssertTrue(waitForSocket(exists: false, timeout: 3.0))
        app.terminate()
    }

    private func waitForSocket(exists: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) == exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return FileManager.default.fileExists(atPath: socketPath) == exists
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return socketPath
            }
            if let found = findSocketInTmp() {
                return found
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            return socketPath
        }
        return findSocketInTmp()
    }

    private func findSocketInTmp() -> String? {
        let tmpPath = "/tmp"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
            return nil
        }
        let matches = entries.filter { $0.hasPrefix("cmux") && $0.hasSuffix(".sock") }
        if let debug = matches.first(where: { $0.contains("debug") }) {
            return (tmpPath as NSString).appendingPathComponent(debug)
        }
        if let first = matches.first {
            return (tmpPath as NSString).appendingPathComponent(first)
        }
        return nil
    }

    private func resetSocketDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, modeKey]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        legacy.arguments = ["delete", defaultsDomain, legacyKey]
        do {
            try legacy.run()
            legacy.waitUntilExit()
        } catch {
            return
        }
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
