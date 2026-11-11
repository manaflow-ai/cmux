import Foundation

/// What the card's Computer picker lists, in order: this Chief's computer and This Mac, then the
/// account's other Cloud machines under a heading, then New Cloud Computer…. Machines tooling made
/// for itself stay out unless the Chief is using one.
nonisolated struct HomeChiefComputerMenu: Equatable {
    enum Row: Equatable {
        /// A computer to pick: `target` is engine.json's `computer`, nil for This Mac.
        case computer(title: String, target: String?)
        case heading(String)
        case separator
        case new
    }

    var rows: [Row]

    /// - Parameters:
    ///   - chief: The Chief's name; empty until the card knows it.
    ///   - computer: engine.json's `computer`, nil for This Mac.
    ///   - machines: The account's Cloud machines.
    init(chief: String, computer: String?, machines: [HomeChiefCloudComputer]) {
        let attached = machines.first { $0.target == computer }
        let named = machines.filter { $0.id != attached?.id && Self.isNamed($0.title, after: chief) }
        let own = (attached.map { [$0] } ?? []) + named
        let others = machines.filter { machine in !machine.isInternal && !own.contains { $0.id == machine.id } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var rows = own.map { Row.computer(title: Self.title(of: $0, attachedTo: attached?.id == $0.id ? chief : ""), target: $0.target) }
        // The Chief's own computer (Set Up Computer in its profile) is no Cloud machine of the list; a
        // machine the list lost (deleted, or the list still loading) stays shown by its target.
        if let computer, attached == nil {
            let own = computer.hasPrefix("chief:")
            let title = !own ? computer : chief.isEmpty ? HomeEngineStrings.computerOwn : HomeEngineStrings.computerName(chief)
            rows.insert(.computer(title: title, target: computer), at: 0)
        }
        rows.append(.computer(title: HomeEngineStrings.computerThisMac, target: nil))
        if !others.isEmpty {
            rows += [.separator, .heading(HomeEngineStrings.computerOthers)]
            rows += others.map { .computer(title: $0.title, target: $0.target) }
        }
        self.rows = rows + [.separator, .new]
    }

    /// A machine's name in the picker: the Chief's computer while its generic name waits to be replaced.
    private static func title(of machine: HomeChiefCloudComputer, attachedTo chief: String) -> String {
        machine.isGenericName && !chief.isEmpty ? HomeEngineStrings.computerName(chief) : machine.title
    }

    /// Whether `title` is `chief`'s computer's name, its numbered form included ("Ada 2’s Computer").
    static func isNamed(_ title: String, after chief: String) -> Bool {
        guard !chief.isEmpty else { return false }
        if title == HomeEngineStrings.computerName(chief) { return true }
        let parts = HomeEngineStrings.computerName("\(chief) \u{1}").components(separatedBy: "\u{1}")
        guard parts.count == 2, title.hasPrefix(parts[0]), title.hasSuffix(parts[1]),
              title.count > parts[0].count + parts[1].count else { return false }
        return title.dropFirst(parts[0].count).dropLast(parts[1].count).allSatisfy(\.isNumber)
    }
}
