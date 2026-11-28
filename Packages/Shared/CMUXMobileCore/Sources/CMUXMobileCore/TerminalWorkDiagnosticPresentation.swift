/// Formats the bounded phase vocabulary outside the measured work.
struct TerminalWorkDiagnosticPresentation {
    let localization: DiagnosticLocalization

    func describe(
        _ event: DiagnosticEvent,
        work: TerminalWorkDiagnostic
    ) -> DiagnosticEventPresentation.DescribedEvent {
        var fields: [DiagnosticEventPresentation.Field] = [
            .init(key: "phase", value: work.phase.rawValue),
            .init(key: "transition", value: work.context.transition.rawValue),
            .init(key: "population", value: work.context.population.rawValue),
            .init(key: "main_thread", value: work.onMainThread ? "1" : "0")
        ]
        if let count = work.context.workspaceCount { fields.append(.init(key: "workspace_count", value: String(count))) }
        if let count = work.context.surfaceCount { fields.append(.init(key: "surface_count", value: String(count))) }
        if let raw = event.ms {
            let ms = Int(raw)
            fields.append(.init(key: "duration", value: localization.string("diagnostics.duration.milliseconds", defaultValue: "\(ms) ms")))
        }
        let name = event.code == .terminalWorkStarted
            ? localization.string("diagnostics.event.terminalWorkStarted", defaultValue: "Terminal phase started")
            : localization.string("diagnostics.event.terminalWorkFinished", defaultValue: "Terminal phase completed")
        return .init(name: name, fields: fields)
    }
}
