import Foundation

/// A precomputed dotted-key path into a JSON object tree.
///
/// The cmux JSON config file is a tree of nested objects
/// (`{"app": {"appearance": "dark"}}`). `JSONPath` represents one leaf
/// address (`"app.appearance"`) as a list of components, split once at
/// construction so hot read/write paths do no string-splitting per call.
///
/// Operations preserve sibling values at every level. ``remove(in:)`` also
/// prunes parent objects that become empty after the removal.
public struct JSONPath: Sendable, Hashable {
    /// The path segments, in order. For `"app.appearance"` this is
    /// `["app", "appearance"]`. Constructed paths are always non-empty.
    public let components: [String]

    /// Creates a `JSONPath` from a dotted string.
    ///
    /// - Parameter dottedPath: A non-empty dotted identifier, e.g.
    ///   `"app.appearance"`. The string is split on `"."` once; subsequent
    ///   operations reuse the precomputed components. Trapping in debug
    ///   builds on empty input — empty paths are a programmer error.
    public init(dottedPath: String) {
        precondition(!dottedPath.isEmpty, "JSONPath requires a non-empty dotted path")
        // `split(separator:)` with default `omittingEmptySubsequences: true`
        // would silently swallow consecutive dots; we use the non-omitting
        // variant and then validate to catch malformed paths like
        // "app..appearance" or ".leading" or "trailing." as programmer errors.
        let segments = dottedPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        precondition(
            !segments.contains(""),
            "JSONPath contains an empty component (leading/trailing dot or consecutive dots): \(dottedPath)"
        )
        self.components = segments
    }

    /// Returns the value at this path inside ``root``, or `nil` when any
    /// segment is missing or has the wrong type.
    public func lookup(in root: [String: Any]) -> Any? {
        guard !components.isEmpty else { return nil }
        var cursor: Any = root
        for component in components {
            guard let dictionary = cursor as? [String: Any], let next = dictionary[component] else {
                return nil
            }
            cursor = next
        }
        return cursor
    }

    /// Assigns ``value`` at this path inside ``root``, creating intermediate
    /// objects as needed. Sibling values are preserved at every level.
    public func assign(_ value: Any, in root: inout [String: Any]) {
        guard !components.isEmpty else { return }
        assignAtPath(components[...], value, in: &root)
    }

    /// Removes the leaf at this path from ``root``. Parent objects that
    /// become empty as a result are also removed.
    public func remove(in root: inout [String: Any]) {
        guard !components.isEmpty else { return }
        removeAtPath(components[...], in: &root)
    }
}

// MARK: - Recursive helpers
//
// File-scope private. These are pure helpers — they have no relationship to
// any `JSONPath` instance and never read its stored ``JSONPath/components``
// (which would be the full original path, not the sliced view that the
// recursion is processing at the current depth). File-scope private says
// "internal to this file, no type-level meaning" without the
// connotation of "type-level operation" that `private static` would carry.
//
// They take `ArraySlice<String>` rather than `[String]` so descending one
// level is `dropFirst()` (a non-allocating view) instead of a fresh
// `Array(components.dropFirst())` copy. The cost of writing or removing a
// path of depth `n` is `O(n)`, not `O(n²)`.

/// Writes ``value`` at the leaf identified by ``components`` inside
/// ``dictionary``, creating intermediate object levels along the way.
///
/// Sibling values at each level are preserved. If a path segment exists but
/// maps to a non-dictionary value (e.g. the JSON had a primitive where we
/// expected an object), that segment is overwritten with a new empty object
/// before the descent continues — write wins.
///
/// - Parameters:
///   - components: The remaining path segments at this recursion depth.
///     Empty means there is nothing to assign; recursion terminates
///     immediately. Length 1 means the current ``dictionary`` is the leaf
///     parent and we write into it directly.
///   - value: The `JSONSerialization`-compatible value to assign at the
///     leaf.
///   - dictionary: The dictionary at the current depth, mutated in place.
private func assignAtPath(
    _ components: ArraySlice<String>,
    _ value: Any,
    in dictionary: inout [String: Any]
) {
    guard let head = components.first else { return }
    if components.count == 1 {
        dictionary[head] = value
        return
    }
    var child = dictionary[head] as? [String: Any] ?? [:]
    assignAtPath(components.dropFirst(), value, in: &child)
    dictionary[head] = child
}

/// Removes the leaf identified by ``components`` from ``dictionary`` and
/// prunes parent objects that become empty as a result.
///
/// If a path segment is missing, or maps to a non-dictionary value before
/// reaching the leaf, the call is a no-op — there is nothing to remove.
/// After unwinding the recursion, each level checks whether its child
/// dictionary became empty; if so, the parent removes that child's entry
/// too. The empty-prune is what lets writes-then-reset round-trip to a
/// clean file with no orphan empty sections.
///
/// - Parameters:
///   - components: The remaining path segments at this recursion depth.
///     Empty means there is nothing to remove. Length 1 means the current
///     ``dictionary`` is the leaf parent and the leaf key is removed
///     directly.
///   - dictionary: The dictionary at the current depth, mutated in place.
private func removeAtPath(
    _ components: ArraySlice<String>,
    in dictionary: inout [String: Any]
) {
    guard let head = components.first else { return }
    if components.count == 1 {
        dictionary.removeValue(forKey: head)
        return
    }
    guard var child = dictionary[head] as? [String: Any] else { return }
    removeAtPath(components.dropFirst(), in: &child)
    if child.isEmpty {
        dictionary.removeValue(forKey: head)
    } else {
        dictionary[head] = child
    }
}
