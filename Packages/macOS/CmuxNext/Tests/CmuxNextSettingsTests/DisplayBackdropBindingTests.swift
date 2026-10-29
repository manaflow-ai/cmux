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
        app.setBackdropSelection(.art(.munchScream))
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
        await binding.folderRefresh?.value
        let expected = BackdropShuffle(source: .folder(folder), rotation: .quarterHour)
        #expect(left.backdropSelection == expected.pick(on: date, calendar: calendar))
        let rightBefore = right.backdropSelection
        let leftBefore = left.backdropSelection
        date = date.addingTimeInterval(900)
        center.post(name: .NSSystemClockDidChange, object: nil)
        for _ in 0..<50 { await Task.yield() }
        await binding.folderRefresh?.value
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

    @Test func folderListingRunsOffMainActor() async {
        let scope = ThemeScope(level: .room)
        let binding = DisplayBackdropBinding(window: NSWindow(), scope: scope, displayID: { first }, listFolder: { Self.folderFixture($0) })
        defer { binding.stop() }
        binding.apply(["appearance": ["displayBackgrounds": .object([first: "folder:/wallpapers"])]])
        await binding.folderRefresh?.value
        #expect(scope.backdropSelection == .art(.munchScream))
    }

    // Foundation marks Thread.isMainThread noasync; this synchronous probe observes the lister's executing thread.
    private nonisolated static func folderFixture(_ path: String) -> [BackdropSelection] {
        #expect(!Thread.isMainThread, "Folder resolution and enumeration must not run on the UI thread")
        return [.art(.munchScream)]
    }

    @Test func slowFolderReadDoesNotBlockRefreshAndStaleResultsCannotWin() async {
        let loader = SuspendedBackdropFolderListing()
        let app = ThemeScope(level: .room)
        app.setBackdropSelection(.art(.munchScream))
        let scope = ThemeScope(level: .room, parent: app)
        var display = first
        var date = Date(timeIntervalSince1970: 1_791_938_451)
        let binding = DisplayBackdropBinding(window: NSWindow(), scope: scope, displayID: { display }, now: { date },
                                            listFolder: { await loader.list($0) })
        defer { binding.stop() }
        let root: JSONValue = ["appearance": [
            "displayBackgrounds": .object([first: "folder:/slow", second: "folder:/new"]),
            "displayBackgroundRotations": .object([second: "15m"]),
        ]]
        binding.apply(root)
        // This executes on the main actor before the slow lister is released: refresh must return immediately.
        #expect(scope.backdropSelection == nil)
        await loader.started("/slow", count: 1)
        let stale = binding.folderRefresh
        display = second
        binding.apply(root)
        await loader.started("/new", count: 1)
        await loader.finish("/new", pictures: [.art(.hokusaiGreatWave)])
        await binding.folderRefresh?.value
        #expect(scope.backdropSelection == .art(.hokusaiGreatWave))
        await loader.finish("/slow", pictures: [.art(.munchScream)])
        await stale?.value
        #expect(scope.backdropSelection == .art(.hokusaiGreatWave), "A stale display's completion must not overwrite the new selection")
        binding.apply(root)
        await binding.folderRefresh?.value
        #expect(await loader.count("/new") == 1, "Settings refreshes reuse the folder listing during its rotation period")
        date = date.addingTimeInterval(900)
        binding.apply(root)
        await loader.started("/new", count: 2)
        let stopped = binding.folderRefresh
        binding.stop()
        await loader.finish("/new", pictures: [.art(.hokusaiGreatWave)])
        await stopped?.value
        #expect(scope.backdropSelection == app.backdropSelection, "A completion after stop must not restore the display override")
    }

    @Test func pendingFolderReadDoesNotRetainBinding() async {
        let loader = SuspendedBackdropFolderListing()
        var binding: DisplayBackdropBinding? = DisplayBackdropBinding(window: NSWindow(), scope: ThemeScope(level: .room),
                                                                      displayID: { first }, listFolder: { await loader.list($0) })
        weak var released = binding
        binding?.apply(["appearance": ["displayBackgrounds": .object([first: "folder:/slow"])]])
        await loader.started("/slow", count: 1)
        let pending = binding?.folderRefresh
        binding = nil
        #expect(released == nil)
        await loader.finish("/slow", pictures: [.art(.munchScream)])
        await pending?.value
    }

    @Test func shorteningCadenceExpiresTheFolderListingAtTheNextTurn() async {
        let loader = SuspendedBackdropFolderListing()
        let scope = ThemeScope(level: .room)
        var date = Date(timeIntervalSince1970: 1_791_938_451)
        let binding = DisplayBackdropBinding(window: NSWindow(), scope: scope, displayID: { first }, now: { date },
                                            listFolder: { await loader.immediateList($0) })
        defer { binding.stop() }
        var root: JSONValue = ["appearance": ["displayBackgrounds": .object([first: "folder:/changing"])]]
        binding.apply(root)
        await binding.folderRefresh?.value
        #expect(scope.backdropSelection == .art(.munchScream))
        root = ["appearance": ["displayBackgrounds": .object([first: "folder:/changing"]),
                               "displayBackgroundRotations": .object([first: "15m"])]]
        binding.apply(root)
        date = date.addingTimeInterval(900)
        binding.apply(root)
        await binding.folderRefresh?.value
        #expect(await loader.count("/changing") == 2)
        #expect(scope.backdropSelection == .art(.hokusaiGreatWave), "New folder contents appear at the shortened cadence")
    }

    @Test func inactiveReadKeepsItsOriginalExpiry() async {
        let loader = SuspendedBackdropFolderListing()
        let scope = ThemeScope(level: .room)
        var display = first
        var date = Date(timeIntervalSince1970: 1_791_938_451)
        let binding = DisplayBackdropBinding(window: NSWindow(), scope: scope, displayID: { display }, now: { date },
                                            listFolder: { await loader.list($0) })
        defer { binding.stop() }
        let root: JSONValue = ["appearance": ["displayBackgrounds": .object([first: "folder:/inactive", second: "none"])]]
        binding.apply(root)
        await loader.started("/inactive", count: 1)
        let stale = binding.folderRefresh
        display = second
        binding.apply(root)
        await loader.finish("/inactive", pictures: [.art(.munchScream)])
        await stale?.value
        date = date.addingTimeInterval(86_400)
        await loader.useImmediateResults(for: "/inactive")
        display = first
        binding.apply(root)
        await binding.folderRefresh?.value
        #expect(await loader.count("/inactive") == 2)
        #expect(scope.backdropSelection == .art(.hokusaiGreatWave), "Returning to an inactive display must not renew stale folder contents")
    }

    @Test func defaultsOptOutWorkspacePriorityAndCleanup() async {
        let app = ThemeScope(level: .room)
        app.setBackdropSelection(.art(.munchScream))
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
        room.pinBackdrop(.selection(.art(.munchScream)))
        #expect(room.backdropSelection == .art(.munchScream), "An explicit window choice wins over its display")
        binding.apply(["appearance": ["displayBackgrounds": .object([first: "none"]) ]])
        #expect(room.backdropSelection == .art(.munchScream), "Display refresh does not erase an explicit window choice")
        room.pinBackdrop(.inherit)
        let workspace = ThemeScope(level: .workspace, parent: room)
        workspace.pinBackdrop(.selection(.art(.munchScream)))
        room.show(workspace)
        #expect(room.backdropSelection == .art(.munchScream))
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
            temporary.stop()
        }
        #expect(released == nil, "Observers and the rotation timer must not retain their window binding")
    }
}
