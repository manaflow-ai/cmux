// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Renders a snapshot as compact indexed text (one element per line, tab
/// indented), the format agents read best and the one Codex Computer Use
/// uses: `12 button Description: 9, ID: Nine`.
struct TreeRenderer: Sendable {
    /// Long values are cut so one text area cannot flood the context.
    var maxValueLength = 300

    func render(_ elements: [SnapshotElement]) -> String {
        var text = ""
        text.reserveCapacity(elements.count * 48)
        for (index, element) in elements.enumerated() {
            text += line(index: index, element.info)
            text += "\n"
        }
        return text
    }

    func line(index: Int, _ info: AXNodeInfo) -> String {
        var line = String(repeating: "\t", count: info.depth)
        line += "\(index) \(roleText(info))"
        let title = clean(info.title)
        if let title { line += " \(title)" }
        var flags: [String] = []
        if !info.enabled { flags.append("disabled") }
        if info.selected { flags.append("selected") }
        if info.focused { flags.append("focused") }
        if info.valueSettable { flags.append("settable") }
        if !flags.isEmpty { line += " (\(flags.joined(separator: ", ")))" }
        var details: [String] = []
        if let label = clean(info.label), label != title { details.append("Description: \(label)") }
        if let value = clean(info.value), value != title {
            details.append("Value: \(value.count > maxValueLength ? String(value.prefix(maxValueLength)) + "…" : value)")
        }
        if let help = clean(info.help) { details.append("Help: \(help)") }
        if let id = clean(info.identifier) { details.append("ID: \(id)") }
        let secondary = info.actions.compactMap(Self.secondaryName)
        if !secondary.isEmpty { details.append("Secondary Actions: \(secondary.joined(separator: ", "))") }
        if !details.isEmpty { line += (title == nil ? " " : ", ") + details.joined(separator: ", ") }
        return line
    }

    func roleText(_ info: AXNodeInfo) -> String {
        if let description = clean(info.roleDescription) { return description }
        guard let role = info.role else { return "element" }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// AXPress is the primary action (a click); every other action is listed.
    static func secondaryName(_ action: String) -> String? {
        switch action {
        case "AXPress": nil
        case "AXShowMenu": "Show Menu"
        case "AXRaise": "Raise"
        case "AXIncrement": "Increment"
        case "AXDecrement": "Decrement"
        case "AXConfirm": "Confirm"
        case "AXCancel": "Cancel"
        case "AXPick": "Pick"
        case "AXShowDefaultUI": "Show Default UI"
        case "AXShowAlternateUI": "Show Alternate UI"
        case "AXScrollToVisible": nil
        default:
            action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
        }
    }

    /// The AX action an agent's secondary action name means on `info`.
    static func axAction(named name: String, in info: AXNodeInfo) -> String? {
        let wanted = name.lowercased().replacingOccurrences(of: " ", with: "")
        return info.actions.first { action in
            let friendly = (secondaryName(action) ?? action).lowercased().replacingOccurrences(of: " ", with: "")
            return friendly == wanted || action.lowercased() == wanted || action.lowercased() == "ax" + wanted
        }
    }
}
