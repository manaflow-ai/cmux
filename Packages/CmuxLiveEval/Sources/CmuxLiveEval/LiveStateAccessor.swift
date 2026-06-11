import CmuxSwiftRender
import SwiftSyntax
import SwiftUI

/// A read/write accessor over interpreted observable state, resolved from a
/// binding expression (`$text`, `$row.isOn`) or an assignment target
/// (`count`, `rows`).
///
/// Reads go through ``StateBox/value``, so a `get` performed inside any
/// Observation tracking scope (a SwiftUI body, a real `Binding` getter run
/// during a control's update) registers a dependency on exactly the backing
/// box. Writes replace the box value, triggering invalidation of every
/// registered reader.
///
/// Two root forms exist: a whole box (`$text`), and a row of a collection box
/// located by identity (`$row.isOn` inside `ForEach($rows, id: \.id)`), where
/// writes rebuild the array with only the identified element replaced.
public struct LiveStateAccessor: Sendable {
    enum Root: Sendable {
        case box(StateBox)
        case element(LiveBindingProvenance)
    }

    let root: Root
    let path: [String]

    /// Resolves a projected binding expression (`$name` or `$name.member…`).
    public static func resolve(_ expression: ExprSyntax, _ scope: LiveScope) -> LiveStateAccessor? {
        resolveTarget(expression, scope, requireProjection: true)
    }

    /// Resolves an assignment target (`name`, `name.member…`, `$name` also
    /// accepted) for action statements.
    public static func resolveAssignable(_ expression: ExprSyntax, _ scope: LiveScope) -> LiveStateAccessor? {
        resolveTarget(expression, scope, requireProjection: false)
    }

    private static func resolveTarget(
        _ expression: ExprSyntax,
        _ scope: LiveScope,
        requireProjection: Bool
    ) -> LiveStateAccessor? {
        var path: [String] = []
        var current = expression
        while let member = current.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return nil }
            path.insert(member.declName.baseName.text, at: 0)
            current = base
        }
        guard let reference = current.as(DeclReferenceExprSyntax.self) else { return nil }
        var name = reference.baseName.text
        if name.hasPrefix("$") {
            name = String(name.dropFirst())
        } else if requireProjection {
            return nil
        }
        if let provenance = scope.provenance(name) {
            return LiveStateAccessor(root: .element(provenance), path: path)
        }
        if let box = scope.stateBox(name) {
            return LiveStateAccessor(root: .box(box), path: path)
        }
        return nil
    }

    // MARK: - Read / write

    /// The current value at the accessor's path. Registers an Observation
    /// dependency on the backing box when called inside a tracking scope.
    public func currentValue() -> SwiftValue? {
        baseValue()?.value(at: path)
    }

    /// Replaces the value at the accessor's path, invalidating every reader
    /// registered on the backing box.
    public func setValue(_ newValue: SwiftValue) {
        switch root {
        case let .box(box):
            box.value = box.value.settingValue(newValue, at: path)
        case let .element(provenance):
            guard case var .array(values) = provenance.box.value,
                  let index = values.firstIndex(where: { Self.matches($0, provenance) })
            else { return }
            values[index] = values[index].settingValue(newValue, at: path)
            provenance.box.value = .array(values)
        }
    }

    private func baseValue() -> SwiftValue? {
        switch root {
        case let .box(box):
            return box.value
        case let .element(provenance):
            guard case let .array(values) = provenance.box.value else { return nil }
            return values.first { Self.matches($0, provenance) }
        }
    }

    private static func matches(_ element: SwiftValue, _ provenance: LiveBindingProvenance) -> Bool {
        guard let idField = provenance.idField else { return element == provenance.idValue }
        return element.member(idField) == provenance.idValue
    }

    // MARK: - SwiftUI bindings

    /// A real SwiftUI Binding over the accessor, for `TextField(text:)`.
    public func stringBinding() -> Binding<String> {
        Binding(
            get: {
                guard let value = currentValue() else { return "" }
                if case let .string(string) = value { return string }
                return value.displayString
            },
            set: { setValue(.string($0)) }
        )
    }

    /// A real SwiftUI Binding over the accessor, for `Toggle(isOn:)`.
    public func boolBinding() -> Binding<Bool> {
        Binding(
            get: { currentValue()?.isTruthy ?? false },
            set: { setValue(.bool($0)) }
        )
    }
}

extension SwiftValue {
    /// Walks `path` member-by-member (`["isOn"]`, `["user", "name"]`).
    func value(at path: [String]) -> SwiftValue? {
        var current = self
        for component in path {
            guard let next = current.member(component) else { return nil }
            current = next
        }
        return current
    }

    /// A copy with the value at `path` replaced. Intermediate components must
    /// be objects; an empty path returns `newValue` itself.
    func settingValue(_ newValue: SwiftValue, at path: [String]) -> SwiftValue {
        guard let head = path.first else { return newValue }
        guard case var .object(fields) = self else { return self }
        let child = fields[head] ?? .object([:])
        fields[head] = child.settingValue(newValue, at: Array(path.dropFirst()))
        return .object(fields)
    }
}
