public import Foundation

/// Expands `${event.*}` tokens in event-hook arguments.
public struct HookArgumentExpander: Sendable {
    private let envelope: AnyJSONValue?

    /// Creates an argument expander.
    /// - Parameter envelopeJSON: The event envelope JSON supplied to the event hook.
    public init(envelopeJSON: Data) {
        if let object = try? JSONSerialization.jsonObject(with: envelopeJSON) {
            self.envelope = AnyJSONValue(object)
        } else {
            self.envelope = nil
        }
    }

    /// Expands all event tokens in `arguments`.
    /// - Parameter arguments: Arguments that may contain `${event.<dot.path>}` tokens.
    /// - Returns: Arguments with supported event tokens expanded.
    public func expand(_ arguments: [String]) -> [String] {
        arguments.map(expand)
    }

    private func expand(_ argument: String) -> String {
        var output = ""
        var index = argument.startIndex
        while index < argument.endIndex {
            guard argument[index] == "$" else {
                output.append(argument[index])
                index = argument.index(after: index)
                continue
            }
            let next = argument.index(after: index)
            guard next < argument.endIndex, argument[next] == "{" else {
                output.append(argument[index])
                index = next
                continue
            }
            guard let close = argument[next...].firstIndex(of: "}") else {
                output.append(argument[index])
                index = next
                continue
            }
            let tokenStart = argument.index(after: next)
            let token = String(argument[tokenStart..<close])
            if token.hasPrefix("event.") {
                let path = String(token.dropFirst("event.".count))
                output.append(value(at: path))
            } else {
                output.append(String(argument[index...close]))
            }
            index = argument.index(after: close)
        }
        return output
    }

    private func value(at path: String) -> String {
        guard let envelope else { return "" }
        var current: AnyJSONValue? = envelope
        for component in path.split(separator: ".").map(String.init) {
            current = current?.child(named: component)
        }
        return current?.argumentText ?? ""
    }
}
