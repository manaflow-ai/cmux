import Foundation
import os
import Testing
@testable import CmuxNextBrowser

/// `BrowserDownloadPolicy.place` looks names up off the main thread: the
/// first look into ~/Downloads waits for macOS's access prompt, and on the
/// main thread it froze the app (every WebKit download in a fresh copy of
/// the app: no download listed, every control call timed out).
@MainActor
@Suite struct BrowserDownloadPlaceTests {
    private let directory = URL(filePath: "/nonexistent-cmux-place-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func namesAreLookedUpOffTheMainThread() async throws {
        let onMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let placement = try await BrowserDownloadPolicy.place(
            chosen: nil, suggestedFilename: "login.bin", directory: directory,
            reservations: BrowserDownloadReservations(),
            probe: { url in
                onMain.withLock { $0.append(Thread.isMainThread) }
                return url.lastPathComponent == "login.bin" ? .present : .absent
            }
        ).get()
        defer { placement.discard() }
        #expect(placement.finalURL.lastPathComponent == "login (1).bin")
        let looks = onMain.withLock { $0 }
        #expect(looks.count == 2)
        #expect(!looks.contains(true), "a name was looked up on the main thread")
    }

    @Test func aRefusedFolderFailsAtItsFirstLook() async {
        let looks = OSAllocatedUnfairLock(initialState: 0)
        let placed = await BrowserDownloadPolicy.place(
            chosen: nil, suggestedFilename: "login.bin", directory: directory,
            reservations: BrowserDownloadReservations(),
            probe: { _ in
                looks.withLock { $0 += 1 }
                return .denied
            }
        )
        guard case .failure(let failure) = placed else {
            Issue.record("a refused folder placed \(placed)")
            return
        }
        #expect(failure == .folderDenied)
        #expect(looks.withLock { $0 } == 1)
    }

    @Test func aNameAnotherDownloadHoldsIsSkippedWithoutALook() async throws {
        let reservations = BrowserDownloadReservations()
        let first = try await BrowserDownloadPolicy.place(
            chosen: nil, suggestedFilename: "a.txt", directory: directory,
            reservations: reservations, probe: { _ in .absent }
        ).get()
        defer { first.discard() }
        let looked = OSAllocatedUnfairLock<[String]>(initialState: [])
        let second = try await BrowserDownloadPolicy.place(
            chosen: nil, suggestedFilename: "a.txt", directory: directory,
            reservations: reservations,
            probe: { url in
                looked.withLock { $0.append(url.lastPathComponent) }
                return .absent
            }
        ).get()
        defer { second.discard() }
        #expect(second.finalURL.lastPathComponent == "a (1).txt")
        #expect(looked.withLock { $0 } == ["a (1).txt"])
    }

    @Test func aChosenFileIsNeverLookedUp() async throws {
        let chosen = directory.appending(path: "picked.bin")
        let placement = try await BrowserDownloadPolicy.place(
            chosen: chosen, suggestedFilename: "x.bin", directory: directory,
            reservations: BrowserDownloadReservations(),
            probe: { _ in
                Issue.record("looked up a chosen file")
                return .present
            }
        ).get()
        defer { placement.discard() }
        #expect(placement.finalURL == chosen)
    }
}
