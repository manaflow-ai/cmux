#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import Foundation

struct TaskComposerDirectoryBrowseState: Equatable, Sendable {
    enum LoadKind: Equatable, Hashable, Sendable {
        case replace
        case append
    }

    struct LoadRequest: Equatable, Hashable, Sendable {
        let path: String
        let offset: Int
        let expectedCurrentPath: String?
        let kind: LoadKind
        let generation: Int
    }

    struct LoadFailure: Equatable, Sendable {
        let reason: MobileTaskDirectoryListFailure
        let request: LoadRequest
    }

    struct Snapshot: Equatable, Sendable {
        let currentPath: String
        let parentPath: String?
        let entries: [MobileTaskDirectoryListEntry]
        let nextOffset: Int?
        let totalCount: Int
    }

    private(set) var snapshot: Snapshot?
    private(set) var pendingRequest: LoadRequest?
    private(set) var failure: LoadFailure?
    private(set) var generation = 0

    init(initialPath: String) {
        let path = Self.trimmedPath(initialPath)
        beginLoad(
            path: path.isEmpty ? "~" : path,
            offset: 0,
            expectedCurrentPath: Self.expectedCurrentPath(for: path),
            kind: .replace
        )
    }

    var isLoading: Bool {
        pendingRequest != nil
    }

    var displayPath: String {
        snapshot?.currentPath
            ?? pendingRequest?.path
            ?? failure?.request.path
            ?? "~"
    }

    @discardableResult
    mutating func navigate(to path: String) -> Bool {
        let path = Self.trimmedPath(path)
        guard !path.isEmpty else { return false }

        let expectedCurrentPath = Self.expectedCurrentPath(for: path)
        if let pendingRequest,
           pendingRequest.kind == .replace,
           pendingRequest.path == path {
            return false
        }
        if pendingRequest == nil,
           failure == nil,
           let expectedCurrentPath,
           snapshot?.currentPath == expectedCurrentPath {
            return false
        }

        beginLoad(
            path: path,
            offset: 0,
            expectedCurrentPath: expectedCurrentPath,
            kind: .replace
        )
        return true
    }

    @discardableResult
    mutating func requestNextPage() -> Bool {
        guard pendingRequest == nil,
              failure == nil,
              let snapshot,
              let nextOffset = snapshot.nextOffset else {
            return false
        }

        beginLoad(
            path: snapshot.currentPath,
            offset: nextOffset,
            expectedCurrentPath: snapshot.currentPath,
            kind: .append
        )
        return true
    }

    @discardableResult
    mutating func retryFailedRequest() -> Bool {
        guard let failedRequest = failure?.request else { return false }

        beginLoad(
            path: failedRequest.path,
            offset: failedRequest.offset,
            expectedCurrentPath: failedRequest.expectedCurrentPath,
            kind: failedRequest.kind
        )
        return true
    }

    mutating func resolve(
        _ result: Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>,
        for request: LoadRequest
    ) {
        guard pendingRequest == request else { return }

        switch result {
        case let .success(page):
            receive(page, for: request)
        case .failure(.cancelled):
            cancel(request)
        case let .failure(reason):
            fail(reason, request: request)
        }
    }

    mutating func cancel(_ request: LoadRequest) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
    }

    func navigationDestination(for entry: MobileTaskDirectoryListEntry) -> String? {
        entry.isReadable ? entry.path : nil
    }

    private mutating func beginLoad(
        path: String,
        offset: Int,
        expectedCurrentPath: String?,
        kind: LoadKind
    ) {
        generation &+= 1
        pendingRequest = LoadRequest(
            path: path,
            offset: offset,
            expectedCurrentPath: expectedCurrentPath,
            kind: kind,
            generation: generation
        )
        failure = nil
    }

    private mutating func receive(
        _ page: MobileTaskDirectoryListResponse,
        for request: LoadRequest
    ) {
        guard page.offset == request.offset else {
            fail(.rejected, request: request)
            return
        }

        switch request.kind {
        case .replace:
            guard request.offset == 0,
                  request.expectedCurrentPath.map({ $0 == page.currentPath }) ?? true else {
                fail(.rejected, request: request)
                return
            }
            snapshot = Snapshot(
                currentPath: page.currentPath,
                parentPath: page.parentPath,
                entries: page.entries,
                nextOffset: page.nextOffset,
                totalCount: page.totalCount
            )
        case .append:
            guard let previous = snapshot,
                  let expectedCurrentPath = request.expectedCurrentPath,
                  request.path == previous.currentPath,
                  expectedCurrentPath == previous.currentPath,
                  page.currentPath == expectedCurrentPath,
                  page.parentPath == previous.parentPath,
                  previous.nextOffset == request.offset,
                  previous.entries.count == request.offset,
                  page.totalCount == previous.totalCount,
                  !Self.hasCrossPageDuplicate(
                      existing: previous.entries,
                      incoming: page.entries
                  ),
                  Self.isOrderedAcrossPageBoundary(
                      existing: previous.entries,
                      incoming: page.entries
                  ) else {
                fail(.rejected, request: request)
                return
            }
            snapshot = Snapshot(
                currentPath: previous.currentPath,
                parentPath: previous.parentPath,
                entries: previous.entries + page.entries,
                nextOffset: page.nextOffset,
                totalCount: page.totalCount
            )
        }

        pendingRequest = nil
        failure = nil
    }

    private mutating func fail(
        _ reason: MobileTaskDirectoryListFailure,
        request: LoadRequest
    ) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
        failure = LoadFailure(reason: reason, request: request)
    }

    private static func trimmedPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expectedCurrentPath(for requestedPath: String) -> String? {
        guard requestedPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: requestedPath, isDirectory: true)
            .standardizedFileURL.path
    }

    private static func hasCrossPageDuplicate(
        existing: [MobileTaskDirectoryListEntry],
        incoming: [MobileTaskDirectoryListEntry]
    ) -> Bool {
        let existingPaths = Set(existing.map(\.path))
        return incoming.contains { existingPaths.contains($0.path) }
    }

    private static func isOrderedAcrossPageBoundary(
        existing: [MobileTaskDirectoryListEntry],
        incoming: [MobileTaskDirectoryListEntry]
    ) -> Bool {
        guard let previous = existing.last, let next = incoming.first else { return true }
        if previous.name.utf8.lexicographicallyPrecedes(next.name.utf8) {
            return true
        }
        guard previous.name == next.name else { return false }
        return previous.path.utf8.lexicographicallyPrecedes(next.path.utf8)
    }
}
#endif
