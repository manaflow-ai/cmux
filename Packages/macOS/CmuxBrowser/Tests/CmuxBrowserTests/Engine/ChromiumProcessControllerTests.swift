import Darwin
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium process controller")
struct ChromiumProcessControllerTests {
    @Test
    func closeForcesAProcessThatIgnoresTermination() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = temporaryDirectory.appendingPathComponent("fake-chromium")
        try """
        #!/bin/sh
        trap '' TERM
        printf 'DevTools listening on ws://127.0.0.1:9222/devtools/browser/test\\n' >&2
        exec /bin/sleep 3600
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let controller = ChromiumProcessController(launchTimeout: .seconds(2))
        let application = BrowserApplication(
            bundleIdentifier: "com.cmux.test.fake-chromium",
            bundleURL: temporaryDirectory,
            executableURL: executableURL
        )

        _ = try await controller.start(
            application: application,
            userDataDirectory: temporaryDirectory.appendingPathComponent("profile", isDirectory: true)
        )
        let processIdentifier = try #require(await controller.processIdentifier())
        let closeTask = Task {
            await controller.close()
        }

        let closedBeforeTestDeadline = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await closeTask.value
                return true
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: .seconds(2))
                } catch {
                    return true
                }
                guard !Task.isCancelled else { return true }
                _ = Darwin.kill(processIdentifier, SIGKILL)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            await group.waitForAll()
            return result
        }

        #expect(closedBeforeTestDeadline)
        #expect(await controller.processIdentifier() == nil)
    }
}
