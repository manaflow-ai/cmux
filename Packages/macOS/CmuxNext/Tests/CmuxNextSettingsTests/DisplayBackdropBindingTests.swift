import AppKit
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

@MainActor @Suite(.serialized) struct DisplayBackdropBindingTests {
    let first = "00000000-0000-0000-0000-000000000001"
    let second = "00000000-0000-0000-0000-000000000002"

    @Test func displayFoldersRotateIndependentlyAndWindowMovesFollowTheScreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "display-backdrops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.png", "b.png", "c.png"] { try Data([0]).write(to: directory.appending(path: name)) }
        let folder = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let root: JSONValue = ["appearance": [
            "background": "daily", "backgroundRotation": "daily",
            "displayBackgrounds": .object([first: .string("folder:" + folder), second: "daily"]),
            "displayBackgroundRotations": .object([first: "15m", second: "hourly"]),
        ]]
        let app = ThemeScope(level: .room)
        app.setBackdropSelection(.art(.degasHalevy))
        let left = ThemeScope(level: .room, parent: app)
        let right = ThemeScope(level: .room, parent: app)
        let window = NSWindow()
        let center = NotificationCenter()
        var display: String? = first
        var date = Date(timeIntervalSince1970: 1_791_938_451)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let fixedCalendar = calendar
        let binding = DisplayBackdropBinding(window: window, scope: left, center: center,
                                            displayID: { display }, now: { date }, calendar: { fixedCalendar })
        let other = DisplayBackdropBinding(window: NSWindow(), scope: right, center: center,
                                          displayID: { second }, now: { date }, calendar: { fixedCalendar })
        defer { binding.stop(); other.stop() }
        binding.apply(root)
        other.apply(root)
        let expected = BackdropShuffle(source: .folder(folder), rotation: .quarterHour)
        #expect(left.backdropSelection == expected.pick(on: date, calendar: calendar))
        let rightBefore = right.backdropSelection
        let leftBefore = left.backdropSelection
        date = date.addingTimeInterval(900)
        center.post(name: .NSSystemClockDidChange, object: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(left.backdropSelection == expected.pick(on: date, calendar: calendar))
        #expect(left.backdropSelection != leftBefore)
        #expect(right.backdropSelection == rightBefore)
        display = second
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        for _ in 0..<50 { await Task.yield() }
        #expect(left.backdropSelection == right.backdropSelection)
        display = nil
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        for _ in 0..<50 { await Task.yield() }
        #expect(left.backdropSelection == app.backdropSelection)
    }

    @Test func defaultsOptOutWorkspacePriorityAndCleanup() async {
        let app = ThemeScope(level: .room)
        app.setBackdropSelection(.art(.degasHalevy))
        let room = ThemeScope(level: .room, parent: app)
        let window = NSWindow()
        let center = NotificationCenter()
        var display = first
        let binding = DisplayBackdropBinding(window: window, scope: room, center: center, displayID: { display })
        binding.apply([:])
        #expect(room.backdropSelection == app.backdropSelection)
        binding.apply(["appearance": ["background": "daily"]])
        app.setBackdropSelection(.art(.hokusaiGreatWave))
        #expect(room.backdropSelection == app.backdropSelection, "Unconfigured displays inherit live app previews")
        binding.apply(["appearance": ["displayBackgrounds": .object([first: "none", second: "daily"]) ]])
        #expect(room.backdropSelection == nil)
        room.pinBackdrop(.inherit)
        #expect(room.backdropSelection == nil, "Reapplying room settings preserves the display opt-out")
        room.pinBackdrop(.selection(.art(.degasHalevy)))
        #expect(room.backdropSelection == .art(.degasHalevy), "An explicit window choice wins over its display")
        binding.apply(["appearance": ["displayBackgrounds": .object([first: "none"]) ]])
        #expect(room.backdropSelection == .art(.degasHalevy), "Display refresh does not erase an explicit window choice")
        room.pinBackdrop(.inherit)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.pinBackdrop(.selection(.art(.degasHalevy)))
        room.show(workspace)
        #expect(room.backdropSelection == .art(.degasHalevy))
        workspace.pinBackdrop(.none)
        #expect(room.backdropSelection == nil)
        room.show(nil)
        binding.stop()
        display = second
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        center.post(name: .NSSystemClockDidChange, object: nil)
        for _ in 0..<50 { await Task.yield() }
        #expect(room.backdropSelection == app.backdropSelection, "Stopping releases the display override and its observers")
        weak var released: DisplayBackdropBinding?
        do {
            let temporary = DisplayBackdropBinding(window: window, scope: room, center: center, displayID: { first })
            temporary.apply(["appearance": ["displayBackgrounds": .object([first: "daily"])]])
            released = temporary
        }
        #expect(released == nil, "Observers and the rotation timer must not retain their window binding")
    }
}
