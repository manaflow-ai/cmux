import AppKit
@testable import CmuxNextActions
@testable import CmuxNextChiefPetWiring
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextFloating
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Leo 2026-10-26: "have guys make their own and then, like, upload their own if they have things
/// from elsewhere for the avatars, the Chief avatars." A Chief's own upload (a still or a moving GIF,
/// checked against the limits) is its pet character: the Chief Settings popover's grid offers it after
/// the nine, the pet plays it (still under Reduce Motion), every other surface draws its first frame,
/// and Remove Upload brings back the character picked before. Every picture here is drawn by the test.
@MainActor @Suite(.serialized) struct ChiefAvatarUploadWiringTests {
    static let chief = HomeChiefAvatars.defaultChief
    typealias Fixtures = ChiefAvatarUploadTests

    @Test func thePetReadsAStillAndAMovingGIF() async throws {
        let folder = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        try await uploads.store(from: Fixtures.picture(.png, width: 1600, height: 900, in: folder), for: key, over: "orb")
        let still = try #require(uploads.worn(of: key, over: "orb"))
        #expect(ChiefPetClip(file: still.file)?.frames.count == 1, "the pet draws the 512 px still")
        try await uploads.store(from: Fixtures.picture(.gif, width: 64, height: 64, frames: 3, in: folder), for: key, over: "orb")
        let moving = try #require(uploads.worn(of: key, over: "orb"))
        let clip = try #require(ChiefPetClip(file: moving.file))
        #expect(clip.frames.count == 3 && clip.delays == [0.25, 0.25, 0.25])
    }

    @Test func theUploadIsTheCharacterPictureUntilAnyPickerPicksACharacterOrItIsRemoved() async throws {
        let folder = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let picks = ChiefMascotPicks(defaults: nil, defaultChief: Self.chief)
        let key = ChiefAvatarUploads.key(chief: "agent_scout01")
        picks.remember("fox", for: "agent_scout01")
        let fox = ChiefPetSettingsRows.avatarURL(of: "fox")
        let picture = { ChiefPetSettingsRows.characterPicture(of: "agent_scout01", picks: picks, uploads: uploads, in: nil) }
        #expect(picture() == fox)
        try await uploads.store(from: Fixtures.picture(.jpeg, width: 200, height: 200, in: folder), for: key, over: "fox")
        #expect(picture() == uploads.uploads[key]?.still)
        // Settings > Chiefs (or the config file) picks another character: it shows, the upload is kept.
        picks.remember("orb", for: "agent_scout01")
        #expect(picture() == ChiefPetSettingsRows.avatarURL(of: "orb"))
        #expect(uploads.uploads[key] != nil)
        uploads.wear(key, over: "orb")
        #expect(picture() == uploads.uploads[key]?.still)
        picks.remember("fox", for: "agent_scout01")
        #expect(ChiefPetSettingsRows.characterPicture(of: nil, picks: picks, uploads: uploads, in: nil)
            == ChiefPetSettingsRows.avatarURL(of: nil), "another Chief's upload never shows on the default Chief")
        uploads.wear(key, over: nil)
        #expect(picture() == fox)
        #expect(uploads.uploads[key] != nil, "a picked character keeps the upload")
        uploads.wear(key, over: "fox")
        uploads.remove(key)
        #expect(picture() == fox, "Remove brings back the character picked before")
        #expect(uploads.uploads[key] == nil)
    }

    @Test func thePopoverOffersTheUploadAfterTheNine() async throws {
        let folder = try Fixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let home = folder.appending(path: "brain")
        let popover = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let rows = ChiefPetSettingsRows(settings: { settings }, homes: ChiefPetHomes(),
                                        picks: ChiefMascotPicks(defaults: nil, defaultChief: Self.chief), uploads: uploads)
        rows.install(in: popover, addRow: { popover.addAppearanceRow($0, control: $1) }, open: { false })
        let cell = rows.mascot.uploadCell
        #expect(rows.mascot.cells.count == 10 && rows.mascot.cells.last === cell)
        #expect(!cell.isHidden && cell.accessibilityLabel() == ChiefAvatarUploads.chooseTitle && cell.image != nil)
        #expect(rows.mascot.selectedID == "orb")

        let key = ChiefAvatarUploads.key(chief: Self.chief)
        try await uploads.store(from: Fixtures.picture(.png, width: 96, height: 96, in: folder), for: key, over: "orb")
        await Fixtures.until { rows.mascot.selectedID == ChiefPetMascotGrid.uploadID }
        #expect(rows.mascot.selectedID == ChiefPetMascotGrid.uploadID)
        #expect(cell.accessibilityLabel() == ChiefAvatarUploads.yoursTitle)

        // Fox wears the character and keeps the upload; the upload cell wears it again.
        try #require(rows.mascot.cells.first { $0.id == "fox" }).performClick(nil)
        await Fixtures.until { settings.snapshot.homeChiefPetMascot == "fox" && rows.mascot.selectedID == "fox" }
        #expect(uploads.worn(of: key, over: "fox") == nil && uploads.uploads[key] != nil)
        cell.performClick(nil)
        await Fixtures.until { rows.mascot.selectedID == ChiefPetMascotGrid.uploadID }
        #expect(uploads.worn(of: key, over: "fox") != nil)
        rows.removeUpload()
        await Fixtures.until { rows.mascot.selectedID == "fox" }
        #expect(rows.mascot.selectedID == "fox", "Remove brings back the character picked before")
    }

    @Test func aMovingUploadLoopsOnlyWhenMotionIsAllowed() throws {
        let frames = try (0..<3).map { _ in
            try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        }
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = false
        let loop = try #require(Motion.home.clipAnimation(frames, delays: [0.125, 0.25, 0.125]) as? CAKeyframeAnimation)
        #expect(loop.keyTimes?.map(\.doubleValue) == [0, 0.25, 0.75, 1])
        #expect(loop.repeatCount == .infinity)
        #expect(Motion.home.clipAnimation(Array(frames.prefix(1)), delays: [0.1]) == nil, "a still never loops")
        Motion.reduceMotionOverride = true
        #expect(Motion.home.clipAnimation(frames, delays: [0.125, 0.25, 0.125]) == nil, "Reduce Motion keeps the first frame")
    }
}
