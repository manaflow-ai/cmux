import Foundation
import CmuxNextActions
import CmuxNextPages
import CmuxNextSettings

/// Retains an editor reveal until config or subscription can deliver it, without reloading edits.
@MainActor final class FilePageLineLocation {
    private var pending: FileLineLocation?
    private var listeners: [UUID: (JSONValue) -> Void] = [:]

    func reveal(_ line: FileLineLocation) {
        if listeners.isEmpty { pending = line }
        else { for listener in listeners.values { listener(value(line)) } }
    }

    func take() -> JSONValue? {
        defer { pending = nil }
        return pending.map(value)
    }

    func subscribe(_ listener: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription {
        let id = UUID()
        listeners[id] = listener
        if let pending { self.pending = nil; listener(value(pending)) }
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }

    func close() {
        pending = nil
        listeners.removeAll()
    }

    private func value(_ location: FileLineLocation) -> JSONValue {
        var result: [String: JSONValue] = ["line": JSONValue(location.line)]
        if let column = location.column { result["column"] = JSONValue(column) }
        if let endLine = location.endLine { result["endLine"] = JSONValue(endLine) }
        return .object(result)
    }
}
