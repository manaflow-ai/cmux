import CmuxNextDesign
@testable import CmuxNextUpdater
import Darwin
import Foundation
import Testing

/// Other copies of a cmux bundle (Leo, 2026-11-08, on a team Mac: a new "cmux NIGHTLY.app" and a month-older
/// "cmux NIGHTLY 2.app" with the same bundle id in /Applications, the older one still running after it was moved,
/// and old disk images left mounted): what a second copy is told, where a copy runs from, what a passing copy is
/// offered, and how a move puts the bundle in place.
struct AppCopyPlaceTests {
    private static let id = "com.cmuxterm.app.nightly"

    private static func copy(_ path: String, build: String?, id: String? = id, exists: Bool = true) -> AppCopy {
        AppCopy(path: path, bundleIdentifier: id, version: build.map { "0.\($0)" }, build: build, exists: exists)
    }

    private static func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "app-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func app(at bundle: URL, build: String, id: String = id) throws {
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleVersion": build, "CFBundleShortVersionString": "0.\(build)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        try Data("bin".utf8).write(to: contents.appending(path: "MacOS/cmux"))
    }

    // MARK: Second copies

    @Test func reopeningTheSameCopySaysNothing() {
        let running = Self.copy("/Applications/cmux NIGHTLY.app", build: "200")
        #expect(SecondCopyNotice.decide(running: running, opened: running) == .none, "a Dock click or a URL hands off silently")
    }

    @Test func aNewerCopyOpenedIsOfferedTheSwitch() {
        let running = Self.copy("/Applications/cmux NIGHTLY 2.app", build: "100")
        let opened = Self.copy("/Applications/cmux NIGHTLY.app", build: "200")
        #expect(SecondCopyNotice.decide(running: running, opened: opened) == .tell(running: running, opened: opened, offersSwitch: true))
    }

    @Test func anOlderCopyOpenedIsToldButNotOfferedTheSwitch() {
        let running = Self.copy("/Applications/cmux NIGHTLY.app", build: "200")
        let opened = Self.copy("/Volumes/cmux NIGHTLY 1/cmux NIGHTLY.app", build: "100")
        #expect(SecondCopyNotice.decide(running: running, opened: opened) == .tell(running: running, opened: opened, offersSwitch: false))
        let same = Self.copy("/Volumes/cmux NIGHTLY/cmux NIGHTLY.app", build: "200")
        #expect(SecondCopyNotice.decide(running: running, opened: same) == .tell(running: running, opened: same, offersSwitch: false),
                "the same build from the disk image: which copy runs is still news")
    }

    @Test func aRunningCopyMovedAwayIsOfferedTheSwitch() {
        let running = Self.copy("/Applications/cmux NIGHTLY 2.app", build: "300", exists: false)
        let opened = Self.copy("/Applications/cmux NIGHTLY.app", build: "200")
        #expect(SecondCopyNotice.decide(running: running, opened: opened) == .tell(running: running, opened: opened, offersSwitch: true))
    }

    @Test func theSameCopyReplacedOnDiskWithANewerBuildIsOfferedTheSwitch() {
        let running = Self.copy("/Applications/cmux NIGHTLY.app", build: "100")
        let opened = Self.copy("/Applications/cmux NIGHTLY.app", build: "200")
        #expect(SecondCopyNotice.decide(running: running, opened: opened) == .tell(running: running, opened: opened, offersSwitch: true))
    }

    @Test func buildsCompareNumerically() {
        #expect(Self.copy("/a", build: "4245364216501").isNewer(than: Self.copy("/b", build: "999999999999")))
        #expect(!Self.copy("/a", build: nil).isNewer(than: Self.copy("/b", build: "1")), "an unknown build is never newer")
        #expect(Self.copy("/a", build: "1").isNewer(than: Self.copy("/b", build: nil)))
    }

    @MainActor @Test func theDialogNamesBothCopiesAndOffersTheSwitchOnlyWhenAsked() {
        let running = Self.copy("/Applications/cmux NIGHTLY 2.app", build: "100")
        let opened = Self.copy("/Applications/cmux NIGHTLY.app", build: "200")
        let offered = AppCopyGuide.spec(running: running, opened: opened, offersSwitch: true)
        #expect(offered.buttons.map(\.id) == ["cancel", "switch"])
        #expect(offered.defaultButton?.id == "switch")
        #expect(offered.lines.contains { $0.contains("cmux NIGHTLY 2.app") && $0.contains("0.100 (100)") })
        #expect(offered.lines.contains { $0.contains("/Applications/cmux NIGHTLY.app") && $0.contains("0.200 (200)") })
        let told = AppCopyGuide.spec(running: opened, opened: running, offersSwitch: false)
        #expect(told.buttons.map(\.id) == ["ok"])
    }

    @Test func aLargeBatchGoesInNotesOfAtMostTheLimit() throws {
        let urls = (0..<600).map { URL(filePath: "/tmp/f\($0)") }
        let notes = SecondCopyNote.notes(openedPath: "/Applications/cmux NIGHTLY.app", urls: urls)
        #expect(notes.map(\.urls.count) == [256, 256, 88])
        #expect(notes.flatMap(\.urls) == urls, "no URL lost past the limit")
        #expect(notes.allSatisfy { SecondCopyNote(userInfo: $0.userInfo) == $0 })
        #expect(SecondCopyNote.notes(openedPath: "/a.app", urls: []).count == 1, "a bare launch still says which copy")
    }

    @Test func theNoteCarriesThePathAndTheURLs() throws {
        let note = SecondCopyNote(openedPath: "/Applications/cmux NIGHTLY.app",
                                  urls: [URL(filePath: "/tmp/a file.txt"), try #require(URL(string: "https://example.com/x?y=1"))])
        #expect(SecondCopyNote(userInfo: note.userInfo) == note)
        #expect(SecondCopyNote(userInfo: ["path": "relative/x.app"]) == nil, "only an absolute bundle path")
        #expect(SecondCopyNote(userInfo: nil) == nil)
    }

    // MARK: The hand-off's route

    @Test func theHandOffNeverDropsURLs() {
        let owner = SingleInstanceGuard.Owner(pid: 42, bundlePath: "/Applications/cmux NIGHTLY 2.app",
                                              identity: .init(executablePath: "/x", started: "1.2"))
        #expect(SingleInstanceHandoff.route(owner: owner, bundleExists: { _ in true }, closing: false) == .launchServices(owner))
        #expect(SingleInstanceHandoff.route(owner: owner, bundleExists: { _ in false }, closing: false) == .note,
                "open -a on a moved bundle finds nothing: the note carries the URLs")
        #expect(SingleInstanceHandoff.route(owner: nil, bundleExists: { _ in true }, closing: false) == .retry)
        #expect(SingleInstanceHandoff.route(owner: nil, bundleExists: { _ in true }, closing: true) == .note,
                "past the deadline the URLs go in the note instead of being dropped")
    }

    // MARK: Where a copy runs

    @Test func translocatedAndReadOnlyCopiesArePassing() {
        let translocated = "/private/var/folders/xy/T/AppTranslocation/1234-5678/d/cmux NIGHTLY.app"
        #expect(AppCopyPlace.of(bundlePath: translocated, readOnlyMount: { _ in "/" }) == .translocated)
        #expect(AppCopyPlace.of(bundlePath: "/Volumes/cmux NIGHTLY/cmux NIGHTLY.app", readOnlyMount: { _ in "/Volumes/cmux NIGHTLY" })
            == .readOnlyVolume("/Volumes/cmux NIGHTLY"))
        #expect(AppCopyPlace.of(bundlePath: "/Applications/cmux NIGHTLY.app", readOnlyMount: { _ in nil }) == .installed)
        #expect(!AppCopyPlace.installed.isPassing)
        #expect(AppCopyPlace.translocated.isPassing)
    }

    @Test func theReadOnlyProbeReadsTheVolume() throws {
        #expect(AppCopyPlace.readOnlyMount(of: "/System/Library") != nil, "the sealed system volume is read-only")
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(AppCopyPlace.readOnlyMount(of: root.path) == nil)
    }

    // MARK: The move offer

    @Test func aPassingCopyIsOfferedTheMove() {
        let running = Self.copy("/Volumes/cmux NIGHTLY/cmux NIGHTLY.app", build: "200")
        let place = AppCopyPlace.readOnlyVolume("/Volumes/cmux NIGHTLY"), destination = "/Applications/cmux NIGHTLY.app"
        #expect(AppMoveOffer.decide(running: running, place: .installed, destination: destination, installed: nil) == nil)
        #expect(AppMoveOffer.decide(running: running, place: place, destination: destination, installed: nil) == .move(destination: destination))
        let older = Self.copy(destination, build: "100")
        #expect(AppMoveOffer.decide(running: running, place: place, destination: destination, installed: older)
            == .replace(destination: destination, installed: older))
        let newer = Self.copy(destination, build: "300")
        #expect(AppMoveOffer.decide(running: running, place: .translocated, destination: destination, installed: newer) == .openInstalled(newer))
        let same = Self.copy(destination, build: "200")
        #expect(AppMoveOffer.decide(running: running, place: place, destination: destination, installed: same) == .openInstalled(same))
        let other = Self.copy(destination, build: "1", id: "com.example.other")
        #expect(AppMoveOffer.decide(running: running, place: place, destination: destination, installed: other) == nil,
                "never replaces another app under the same name")
    }

    @Test func theMoveGoesToApplicationsElseTheHomeFolder() {
        #expect(AppMoveOffer.applicationsFolder(writable: { _ in true }, home: "/Users/u") == "/Applications")
        #expect(AppMoveOffer.applicationsFolder(writable: { _ in false }, home: "/Users/u") == "/Users/u/Applications")
    }

    @Test func aMoveCopiesTheBundleAndClearsItsQuarantine() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "volume/cmux NIGHTLY.app", directoryHint: .isDirectory)
        try Self.app(at: source, build: "200")
        let binary = source.appending(path: "Contents/MacOS/cmux").path
        #expect(setxattr(binary, "com.apple.quarantine", "0081;0;Safari;", 14, 0, 0) == 0)
        let destination = root.appending(path: "Applications/cmux NIGHTLY.app").path
        let moved = try AppMoveOffer.move(destination: destination).perform(running: source, trash: { _ in Issue.record("nothing to trash") })
        #expect(moved.path == destination)
        #expect(AppCopy.read(path: destination).build == "200")
        #expect(getxattr(moved.appending(path: "Contents/MacOS/cmux").path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Applications").path) == ["cmux NIGHTLY.app"],
                "no staged copy is left behind")
    }

    @Test func aReplaceTrashesTheOldCopyOnlyOnceTheNewOneIsInPlace() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "volume/cmux NIGHTLY.app", directoryHint: .isDirectory)
        try Self.app(at: source, build: "200")
        let destination = root.appending(path: "Applications/cmux NIGHTLY.app", directoryHint: .isDirectory)
        try Self.app(at: destination, build: "100")
        var trashed: [String] = []
        let offer = AppMoveOffer.replace(destination: destination.path, installed: AppCopy.read(path: destination.path))
        _ = try offer.perform(running: source, trash: { url in
            trashed.append(AppCopy.read(path: url.path).build ?? "?")
            try? FileManager.default.removeItem(at: url)
        })
        #expect(AppCopy.read(path: destination.path).build == "200")
        #expect(trashed == ["100"])
    }

    @Test func aFailedReplaceKeepsTheOldCopy() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appending(path: "Applications/cmux NIGHTLY.app", directoryHint: .isDirectory)
        try Self.app(at: destination, build: "100")
        let missing = root.appending(path: "volume/gone.app", directoryHint: .isDirectory)
        let offer = AppMoveOffer.replace(destination: destination.path, installed: AppCopy.read(path: destination.path))
        #expect(throws: (any Error).self) { try offer.perform(running: missing, trash: { _ in Issue.record("never trashed") }) }
        #expect(AppCopy.read(path: destination.path).build == "100")
    }

    @Test func theReopenEjectsOnlyADiskImage() {
        let command = AppMoveOffer.reopenCommand(pid: 7, app: "/Applications/cmux NIGHTLY.app", ejecting: "/Volumes/cmux NIGHTLY")
        #expect(Array(command.suffix(3)) == ["7", "/Applications/cmux NIGHTLY.app", "/Volumes/cmux NIGHTLY"])
        #expect(AppMoveOffer.reopenCommand(pid: 7, app: "/a.app", ejecting: "/").last == "", "never the root volume")
        #expect(AppMoveOffer.reopenCommand(pid: 7, app: "/a.app", ejecting: nil).last == "")
    }

    @MainActor @Test func theMoveDialogSaysWhy() {
        let spec = AppCopyGuide.spec(place: .readOnlyVolume("/Volumes/cmux NIGHTLY"), offer: .move(destination: "/Applications/cmux NIGHTLY.app"))
        #expect(spec.buttons.map(\.id) == ["cancel", "move"])
        #expect(spec.lines.count == 3, "why, what the move does, and the eject")
        let installed = Self.copy("/Applications/cmux NIGHTLY.app", build: "300")
        #expect(AppCopyGuide.spec(place: .translocated, offer: .openInstalled(installed)).lines.count == 2)
    }
}
