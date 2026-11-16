public import CmuxNextActions

/// Root palette rows that run a machine action on one machine in one step ("Connect to Machine: devbox",
/// "New Workspace on Machine: build-vm", "Open Cloud SSH Terminal: lane-3"), so typing a machine's name
/// finds what to do with it instead of opening the action and then picking the machine. Each row runs
/// the action with the machine the action's own picker would pass: an argument or the target.
/// Rows show only for a typed query, as the Screen Sharing device rows do.
///
/// ```swift
/// let rows = MachinePaletteRows(actions: MachinePaletteRows.standard(targets: { sources.targets }, sshDestinations: { ... }))
/// sources.extraProviders.append(rows.provider(registry: registry))
/// ```
public struct MachinePaletteRows {
    /// How a row hands the machine to its action.
    public enum Pass: Equatable, Sendable {
        /// As the invocation's `machine:` target.
        case target
        /// As the named argument, the option's id as its string value.
        case argument(String)
    }

    /// One action and the machines it lists.
    public struct Action {
        public var id: ActionID
        public var pass: Pass
        /// The machines it runs on now, as its picker lists them; read on each open.
        public var machines: @MainActor () -> [PaletteTargetOption]

        public init(id: ActionID, pass: Pass, machines: @escaping @MainActor () -> [PaletteTargetOption]) {
            (self.id, self.pass, self.machines) = (id, pass, machines)
        }
    }

    public static let providerID = "machines.actions"
    /// The most rows one action adds. The palette ranks a provider's whole list against the query
    /// (providers never see keystrokes), so this sits far above any real machine list: it only keeps
    /// a pathological one from making thousands of rows.
    public static let perActionLimit = 200

    public var actions: [Action]

    public init(actions: [Action]) {
        self.actions = actions
    }

    /// The root provider: each available action's rows, read on each open; none for the empty query.
    public func provider(registry: ActionRegistry) -> AsyncPaletteProvider {
        let actions = actions
        return AsyncPaletteProvider(id: Self.providerID, showsItemsForEmptyQuery: false) { [weak registry] in
            guard let registry else { return [] }
            return actions.flatMap { action -> [PaletteItem] in
                guard registry.isAvailable(action.id), let descriptor = registry.descriptor(for: action.id) else { return [] }
                return Self.rows(action: action.id, title: registry.title(for: action.id) ?? descriptor.title, keywords: descriptor.keywords,
                                 symbol: descriptor.symbol, pass: action.pass, machines: action.machines()) { [weak registry] invocation in
                    _ = registry?.perform(action.id, invocation: invocation)
                }
            }
        }
    }

    /// The rows for `machines`, titled "<action title>: <machine>" (the title's trailing "…" dropped: the
    /// row asks nothing more). Unnamed, disabled and repair rows are skipped, and at most
    /// ``perActionLimit`` rows are made. `perform` runs the action with the row's invocation.
    static func rows(action: ActionID, title: String, keywords: [String], symbol: String, pass: Pass,
                     machines: [PaletteTargetOption], perform: @escaping @MainActor (ActionInvocation) -> Void) -> [PaletteItem] {
        let verb = actionTitle(title)
        guard !verb.isEmpty else { return [] }
        var seen = Set<String>(), usable: [PaletteTargetOption] = []
        for option in machines {
            if usable.count == perActionLimit { break }
            guard option.isEnabled, option.recovery == nil, !option.id.isEmpty,
                  !option.title.trimmingCharacters(in: .whitespaces).isEmpty, seen.insert(option.id).inserted else { continue }
            usable.append(option)
        }
        return usable.map { machine in
            let invocation: ActionInvocation = switch pass {
            case .target: ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine.id), origin: .user)
            case .argument(let name): ActionInvocation(arguments: [name: .string(machine.id)], origin: .user)
            }
            let key = "\(providerID):\(action.rawValue):\(machine.id)"
            var item = PaletteItem(
                id: key,
                title: "\(verb): \(machine.title)",
                subtitle: machine.subtitle,
                symbol: symbol,
                keywords: [machine.title, "machine"] + keywords,
                primary: PaletteCommand(id: "run", title: verb, symbol: "return", effect: .perform { perform(invocation) }),
                frecencyKey: key,
                actionID: action
            )
            item.actionRefs = [PaletteActionRef(action, target: invocation.target, arguments: invocation.arguments)]
            return item
        }
    }

    /// `title` without a trailing ellipsis ("Connect to Machine…" → "Connect to Machine").
    static func actionTitle(_ title: String) -> String {
        var verb = title.trimmingCharacters(in: .whitespaces)
        for mark in ["…", "..."] where verb.hasSuffix(mark) { verb.removeLast(mark.count) }
        return verb.trimmingCharacters(in: .whitespaces)
    }
}

extension MachinePaletteRows {
    /// The machine actions worth a row per machine, each listing what its own picker lists:
    /// Connect to Machine… (an SSH machine's destination, one machine per destination), New Workspace on Machine… (a connected
    /// machine) and Open Cloud SSH Terminal (a Cloud machine). `targets` is the palette's target source.
    public static func standard(targets: @escaping @MainActor () -> (any PaletteTargetSource)?,
                                sshDestinations: @escaping @MainActor () -> [PaletteTargetOption]) -> [Action] {
        func picked(_ id: ActionID) -> @MainActor () -> [PaletteTargetOption] {
            { targets()?.targets(of: .machine, for: id) ?? [] }
        }
        return [
            Action(id: "remote.connect", pass: .argument("destination"), machines: sshDestinations),
            Action(id: "workspace.newOnMachine", pass: .argument("machine"), machines: picked("workspace.newOnMachine")),
            Action(id: "cloudSSH", pass: .target, machines: picked("cloudSSH")),
        ]
    }
}
