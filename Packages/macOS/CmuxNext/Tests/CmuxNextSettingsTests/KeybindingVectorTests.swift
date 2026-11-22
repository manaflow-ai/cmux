import AppKit
import CmuxNextActions
import CmuxNextSettings
import Foundation
import Testing

/// The shared conformance vectors (`schemas/keybindings/keybinding-vectors.json`,
/// R59): the default table of the real catalog, with every action runnable
/// where its catalog context holds, plus each vector's user entries and
/// removals, resolves each key sequence to the expected outcome
/// (`KeyBindingTable.outcome(of:in:isRunnable:)`). Other clients run the
/// same file.
@MainActor
@Suite struct KeybindingVectorTests {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("schemas/keybindings/keybinding-vectors.json")

    struct Vector {
        var name: String
        var context: KeyContext
        var bindings: [KeyBinding]
        var removals: [KeyBindingRemoval]
        var keys: [Shortcut]
        var expect: Expectation
    }

    enum Expectation: Equatable {
        case action(ActionID, [String: ActionValue])
        case armed
        case none
    }

    static func stroke(_ text: String) throws -> Shortcut {
        let spec = try #require(ShortcutBindingFormat.parseStroke(text), "stroke \(text)")
        return SettingsApplier.shortcut(for: spec)
    }

    static func value(_ any: Any) throws -> ActionValue {
        switch any {
        case let flag as Bool where CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID(): .bool(flag)
        case let number as Int: .int(number)
        case let text as String: .string(text)
        default: throw VectorError.unsupported("\(any)")
        }
    }

    enum VectorError: Error { case unsupported(String) }

    static func contextValue(_ any: Any) throws -> KeyContextValue {
        switch any {
        case let flag as Bool where CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID(): .bool(flag)
        case let number as Double: .number(number)
        case let text as String: .string(text)
        default: throw VectorError.unsupported("\(any)")
        }
    }

    static func when(_ text: String?) throws -> WhenClause? {
        guard let text else { return nil }
        return try WhenClause.parse(text)
    }

    static func vectors() throws -> [Vector] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try #require(root["vectors"] as? [[String: Any]])
        return try rows.map { row in
            let context = try (row["context"] as? [String: Any] ?? [:]).mapValues(contextValue)
            let bindings = try (row["bindings"] as? [[String: Any]] ?? []).map { entry in
                KeyBinding(keys: try (entry["key"] as? String ?? "").split(separator: " ").map { try stroke(String($0)) },
                           command: ActionID(rawValue: try #require(entry["command"] as? String)),
                           arguments: try (entry["args"] as? [String: Any] ?? [:]).mapValues(value),
                           when: try when(entry["when"] as? String), source: .user)
            }
            let removals = try (row["removals"] as? [[String: Any]] ?? []).map { entry in
                KeyBindingRemoval(command: ActionID(rawValue: try #require(entry["command"] as? String)),
                                  keys: try (entry["key"] as? String).map { try $0.split(separator: " ").map { try stroke(String($0)) } },
                                  when: try (entry["when"] as? String).map { .exactly(try when($0)) } ?? .any)
            }
            let expect = try #require(row["expect"] as? [String: Any])
            let expectation: Expectation
            if let action = expect["action"] as? String {
                expectation = .action(ActionID(rawValue: action), try (expect["args"] as? [String: Any] ?? [:]).mapValues(value))
            } else if expect["armed"] as? Bool == true {
                expectation = .armed
            } else {
                expectation = .none
            }
            return Vector(name: try #require(row["name"] as? String), context: KeyContext(context), bindings: bindings,
                          removals: removals, keys: try (row["keys"] as? [String] ?? []).map(stroke), expect: expectation)
        }
    }

    @Test func everyVectorResolvesAsTheFileSays() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count >= 20)
        for vector in vectors {
            let registry = ActionRegistry.standard()
            for descriptor in registry.descriptors { registry.bind(descriptor.id, invoke: { _ in }) }
            let issues = KeyBindingLoader(registry).load(KeyBindingLayers(user: vector.bindings, removals: vector.removals))
            #expect(issues.isEmpty, "\(vector.name): \(issues)")
            let bindings = RegistryKeyBindings(registry)
            let outcome = bindings.table.outcome(of: vector.keys.map { [$0] }, in: vector.context) {
                bindings.canPerform($0, in: vector.context.bits)
            }
            let actual: Expectation = switch outcome {
            case .run(let binding): .action(binding.command, binding.arguments)
            case .armed: .armed
            case .none: .none
            }
            #expect(actual == vector.expect, "\(vector.name)")
        }
    }
}
