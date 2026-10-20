public import Foundation

/// Where a Memory Inspector reads and changes one Chief's memory.
///
/// The app's concrete source sends each call over its daemon connection
/// (`chief-inspect`), which forwards it to the Chief's brain; tests pass a
/// fake. A read path (`/api/status`, `/api/view`, `/api/node`, `/api/search`,
/// `/api/memory/changes`) answers its JSON body; a change path
/// (`/api/memory/edit`, `/api/memory/delete`, `/api/memory/undo`) changes the
/// memory and answers the change.
///
/// ```swift
/// let model = ChiefMemoryInspectorModel(source: FakeMemorySource())
/// await model.reload()
/// ```
public protocol ChiefMemorySource: Sendable {
    /// Calls one inspector API path with its query and returns the JSON body.
    ///
    /// - Parameters:
    ///   - path: An `/api/...` path of the brain's inspector.
    ///   - query: The path's parameters, all strings.
    /// - Returns: The answer's JSON body.
    /// - Throws: ``ChiefMemoryError``.
    func call(_ path: String, query: [String: String]) async throws(ChiefMemoryError) -> Data
}

/// Why a Memory Inspector call failed.
public enum ChiefMemoryError: Error, Sendable, Equatable {
    /// No connection reaches the Chief's brain (it is not running, or its
    /// server is offline).
    case unreachable
    /// The brain answered with an error status and its reason (a refused
    /// change, a line that is gone, a later change that must be undone first).
    case refused(status: Int, message: String)
    /// The answer was not the JSON the inspector expects.
    case malformed
}
