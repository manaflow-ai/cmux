#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct TaskComposerDirectoryBrowseStateTests {
    @Test func pageTwoFailurePreservesPageOneAndRetriesTheExactOffset() throws {
        var state = TaskComposerDirectoryBrowseState(initialPath: "/root")
        let firstRequest = try #require(state.pendingRequest)
        state.resolve(
            .success(try Self.page(
                path: "/root",
                entries: [
                    Self.entry(name: "a", path: "/root/a"),
                    Self.entry(name: "b", path: "/root/b"),
                ],
                offset: 0,
                totalCount: 4,
                nextOffset: 2
            )),
            for: firstRequest
        )
        let firstPage = try #require(state.snapshot)

        let didRequestNextPage = state.requestNextPage()
        #expect(didRequestNextPage)
        let failedRequest = try #require(state.pendingRequest)
        state.resolve(.failure(.timedOut), for: failedRequest)

        #expect(state.snapshot == firstPage)
        #expect(state.failure?.reason == .timedOut)
        #expect(state.failure?.request == failedRequest)

        let didRetry = state.retryFailedRequest()
        #expect(didRetry)
        let retryRequest = try #require(state.pendingRequest)
        #expect(retryRequest.path == failedRequest.path)
        #expect(retryRequest.offset == failedRequest.offset)
        #expect(retryRequest.expectedCurrentPath == failedRequest.expectedCurrentPath)
        #expect(retryRequest.kind == failedRequest.kind)
        #expect(retryRequest.generation != failedRequest.generation)

        state.resolve(
            .success(try Self.page(
                path: "/root",
                entries: [
                    Self.entry(name: "c", path: "/root/c"),
                    Self.entry(name: "d", path: "/root/d"),
                ],
                offset: 2,
                totalCount: 4,
                nextOffset: nil
            )),
            for: retryRequest
        )

        #expect(state.snapshot?.entries.map(\.name) == ["a", "b", "c", "d"])
        #expect(state.snapshot?.nextOffset == nil)
        #expect(state.failure == nil)
    }

    @Test func navigationFailurePreservesTheLastSuccessfulDirectory() throws {
        var state = TaskComposerDirectoryBrowseState(initialPath: "/root")
        let initialRequest = try #require(state.pendingRequest)
        state.resolve(
            .success(try Self.page(
                path: "/root",
                entries: [Self.entry(name: "a", path: "/root/a")],
                offset: 0,
                totalCount: 1,
                nextOffset: nil
            )),
            for: initialRequest
        )
        let lastSuccessfulDirectory = try #require(state.snapshot)

        let didNavigate = state.navigate(to: "/restricted")
        #expect(didNavigate)
        let navigationRequest = try #require(state.pendingRequest)
        #expect(state.snapshot == lastSuccessfulDirectory)

        state.resolve(.failure(.permissionDenied), for: navigationRequest)

        #expect(state.snapshot == lastSuccessfulDirectory)
        #expect(state.displayPath == "/root")
        #expect(state.failure?.request == navigationRequest)
    }

    @Test func staleResponseCannotReplaceANewerPendingNavigation() throws {
        var state = TaskComposerDirectoryBrowseState(initialPath: "/first")
        let staleRequest = try #require(state.pendingRequest)
        let didNavigate = state.navigate(to: "/second")
        #expect(didNavigate)
        let currentRequest = try #require(state.pendingRequest)

        state.resolve(
            .success(try Self.page(
                path: "/first",
                entries: [Self.entry(name: "old", path: "/first/old")],
                offset: 0,
                totalCount: 1,
                nextOffset: nil
            )),
            for: staleRequest
        )

        #expect(state.pendingRequest == currentRequest)
        #expect(state.snapshot == nil)
        #expect(state.failure == nil)

        state.resolve(
            .success(try Self.page(
                path: "/second",
                entries: [Self.entry(name: "new", path: "/second/new")],
                offset: 0,
                totalCount: 1,
                nextOffset: nil
            )),
            for: currentRequest
        )
        #expect(state.snapshot?.currentPath == "/second")
    }

    @Test func mismatchedResponsePathAndOffsetAreRejected() throws {
        var wrongPathState = TaskComposerDirectoryBrowseState(initialPath: "/root")
        let wrongPathRequest = try #require(wrongPathState.pendingRequest)
        wrongPathState.resolve(
            .success(try Self.page(
                path: "/other",
                entries: [Self.entry(name: "a", path: "/other/a")],
                offset: 0,
                totalCount: 1,
                nextOffset: nil
            )),
            for: wrongPathRequest
        )
        #expect(wrongPathState.snapshot == nil)
        #expect(wrongPathState.failure?.reason == .rejected)
        #expect(wrongPathState.failure?.request == wrongPathRequest)

        var wrongOffsetState = TaskComposerDirectoryBrowseState(initialPath: "/root")
        let wrongOffsetRequest = try #require(wrongOffsetState.pendingRequest)
        wrongOffsetState.resolve(
            .success(try Self.page(
                path: "/root",
                entries: [Self.entry(name: "b", path: "/root/b")],
                offset: 1,
                totalCount: 2,
                nextOffset: nil
            )),
            for: wrongOffsetRequest
        )
        #expect(wrongOffsetState.snapshot == nil)
        #expect(wrongOffsetState.failure?.reason == .rejected)
        #expect(wrongOffsetState.failure?.request == wrongOffsetRequest)
    }

    @Test func duplicatePathAcrossPagesRejectsTheIncomingPage() throws {
        var state = TaskComposerDirectoryBrowseState(initialPath: "/root")
        let initialRequest = try #require(state.pendingRequest)
        state.resolve(
            .success(try Self.page(
                path: "/root",
                entries: [
                    Self.entry(name: "a", path: "/root/a"),
                    Self.entry(name: "b", path: "/root/b"),
                ],
                offset: 0,
                totalCount: 4,
                nextOffset: 2
            )),
            for: initialRequest
        )
        let firstPage = try #require(state.snapshot)
        let didRequestNextPage = state.requestNextPage()
        #expect(didRequestNextPage)
        let appendRequest = try #require(state.pendingRequest)

        state.resolve(
            .success(try Self.page(
                path: "/root",
                entries: [
                    Self.entry(name: "c", path: "/root/b"),
                    Self.entry(name: "d", path: "/root/d"),
                ],
                offset: 2,
                totalCount: 4,
                nextOffset: nil
            )),
            for: appendRequest
        )

        #expect(state.snapshot == firstPage)
        #expect(state.failure?.reason == .rejected)
        #expect(state.failure?.request == appendRequest)
    }

    @Test func unreadableEntryHasNoNavigationDestination() throws {
        let state = TaskComposerDirectoryBrowseState(initialPath: "/root")
        let readable = Self.entry(name: "readable", path: "/root/readable")
        let unreadable = Self.entry(
            name: "unreadable",
            path: "/root/unreadable",
            isReadable: false
        )

        #expect(state.navigationDestination(for: readable) == "/root/readable")
        #expect(state.navigationDestination(for: unreadable) == nil)
    }

    private static func entry(
        name: String,
        path: String,
        isReadable: Bool = true
    ) -> MobileTaskDirectoryListEntry {
        MobileTaskDirectoryListEntry(
            name: name,
            path: path,
            isHidden: false,
            isPackage: false,
            isSymbolicLink: false,
            isReadable: isReadable
        )!
    }

    private static func page(
        path: String,
        entries: [MobileTaskDirectoryListEntry],
        offset: Int,
        totalCount: Int,
        nextOffset: Int?
    ) throws -> MobileTaskDirectoryListResponse {
        try #require(MobileTaskDirectoryListResponse(
            currentPath: path,
            parentPath: path == "/" ? nil : "/",
            entries: entries,
            offset: offset,
            limit: entries.count,
            totalCount: totalCount,
            nextOffset: nextOffset
        ))
    }
}
#endif
