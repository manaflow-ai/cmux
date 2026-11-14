package import Observation

/// The reads of the vault's session list. One reload is one read of the source. A list that is not complete
/// (``VaultSessionSource/isComplete``: a daemon's fold of its journal is behind) is then read again while a
/// surface that shows it is on screen, with the source's own wait between two reads, until it is complete or
/// ``readLimit`` reads were made. A list that no surface shows is read one time, and again at its next reload.
@MainActor
@Observable
package final class VaultListReads {
    /// The reads of one reload, the first one counted: with the daemon's wait (1 s, 2 s, 4 s, then 8 s each
    /// time; 1 s after each read in the source's quiet start) that is about 5 minutes. A daemon that stays
    /// behind holds no reader for ever; the list keeps its "not complete" mark and the next reload reads again.
    package static let readLimit = 40

    /// The first read of a reload is running.
    package private(set) var isLoading = false
    /// The list is not complete yet: it holds the sessions read so far.
    package private(set) var isPartial = false
    /// The last read started while the source started quietly (``VaultSessionSource/startsQuietly``): it asked
    /// no daemon, so its "not complete" says nothing about a daemon that connected after it.
    package private(set) var readInQuietStart = false
    @ObservationIgnored private var surfaces: [@MainActor () -> Bool?] = []
    @ObservationIgnored private var isReadingAgain = false
    /// The last reload ended with a list that is not complete because no surface showed it.
    @ObservationIgnored private var endedOffScreen = false

    package init() {}

    /// A surface that shows the list says whether it is on screen now (nil: the surface is gone).
    package func addSurface(_ isOnScreen: @escaping @MainActor () -> Bool?) { surfaces.append(isOnScreen) }

    private var isShown: Bool {
        surfaces.removeAll { $0() == nil }
        return surfaces.contains { $0() == true }
    }

    /// True one time when the last reload ended with a list that is not complete because no surface showed it,
    /// and a surface shows it now: the owner reloads. False after an end at ``readLimit`` reads (that list waits
    /// for the person's reload), for a complete list, while a reload reads, and while no surface shows the list.
    /// It reads nothing and waits for nothing.
    package func takeReadsOwedOnScreen() -> Bool {
        guard endedOffScreen, isPartial, !isLoading, isShown else { return false }
        endedOffScreen = false
        return true
    }

    /// Reads `source` and runs `took` after each read (the owner rebuilds its rows from the source).
    package func reload(_ source: any VaultSessionSource, took: () -> Void) async {
        isLoading = true
        endedOffScreen = false
        await read(source, took)
        isLoading = false
        // One reload reads again at a time; a second one made its one read above.
        guard isPartial, !isReadingAgain else { return }
        isReadingAgain = true
        defer { isReadingAgain = false }
        var reads = 1
        // The reads so far that asked no daemon (made in the source's quiet start). They are no reads for the wait: each wait
        // in the quiet start is the first one (1 s), so the list comes at most 1 s after the handshake, then 1, 2, 4, 8 s.
        var quietReads = readInQuietStart ? 1 : 0
        // wakeup-allow: each pass awaits the source's wait (the daemon client's Backoff sleep of 1 s to 8 s, because the daemon sends no event when a list becomes complete), then makes one read; it ends at a complete list, at readLimit reads, when no surface shows the list, and when the reader's task is cancelled
        while isPartial, reads < Self.readLimit, isShown {
            do { try await source.waitForPending(afterReads: reads - quietReads) } catch { return }
            // Another reload completed the list during the wait, or the last surface went away.
            guard isPartial, isShown else {
                endedOffScreen = isPartial
                return
            }
            await read(source, took)
            reads += 1
            if readInQuietStart { quietReads = reads }
        }
        // Not at the bound and not complete: no surface showed the list.
        endedOffScreen = isPartial && reads < Self.readLimit
    }

    private func read(_ source: any VaultSessionSource, _ took: () -> Void) async {
        let quiet = source.startsQuietly
        await source.refresh()
        took()
        isPartial = !source.isComplete
        readInQuietStart = quiet
    }
}
