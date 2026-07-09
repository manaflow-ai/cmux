import CmuxHooks
import Foundation
import os

// @unchecked Sendable: synchronous event-bus and main-actor callers share this
// small file-stat cache; every mutable field is guarded by `state`.
final class CmuxHooksRuntimeConfigCache: @unchecked Sendable {
    private let fileURL: URL
    private let loader: CmuxHooksConfigLoader
    private let state: OSAllocatedUnfairLock<State>

    init(fileURL: URL, loader: CmuxHooksConfigLoader) {
        self.fileURL = fileURL
        self.loader = loader
        self.state = OSAllocatedUnfairLock(initialState: Self.loadedState(fileURL: fileURL, loader: loader))
    }

    func configState() -> CmuxHooksConfigState {
        refreshedState().configState
    }

    func subscribedEventNames() -> Set<String> {
        refreshedState().subscribedEventNames
    }

    private func refreshedState() -> State {
        let stamp = Self.currentStamp(fileURL: fileURL)
        return state.withLock { current in
            guard current.stamp != stamp else { return current }
            current = Self.loadedState(fileURL: fileURL, loader: loader, stamp: stamp)
            return current
        }
    }

    private static func loadedState(
        fileURL: URL,
        loader: CmuxHooksConfigLoader,
        stamp: FileStamp? = nil
    ) -> State {
        let resolvedStamp = stamp ?? currentStamp(fileURL: fileURL)
        let configState = loader.load(fileURL: fileURL)
        return State(
            stamp: resolvedStamp,
            configState: configState,
            subscribedEventNames: subscribedEventNames(in: configState)
        )
    }

    private static func subscribedEventNames(in state: CmuxHooksConfigState) -> Set<String> {
        guard case .loaded(let config) = state else { return [] }
        return Set(config.events.compactMap { name, hooks in
            hooks.contains { $0.enabled } ? name : nil
        })
    }

    private static func currentStamp(fileURL: URL) -> FileStamp {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return .missing
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            return .present(size: size, modificationTime: modificationTime)
        } catch {
            return .inaccessible(String(describing: error))
        }
    }

    private struct State {
        var stamp: FileStamp
        var configState: CmuxHooksConfigState
        var subscribedEventNames: Set<String>
    }

    private enum FileStamp: Equatable {
        case missing
        case present(size: UInt64, modificationTime: TimeInterval)
        case inaccessible(String)
    }
}
