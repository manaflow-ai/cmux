/// `terminal.predictiveLocalEcho` in cmux.json: whether a terminal whose shell
/// runs on another machine draws typed characters before the remote echoes
/// them (the shared prediction engine, `TerminalEchoPrediction`). Default
/// `true`, the opt-out classic cmux documents; the engine still waits for a
/// slow measured echo and skips password prompts and full-screen programs.
/// Running terminals follow a change at once. `configPath` and `fallback` are
/// generated from schemas/settings/source/terminal.json.
public nonisolated struct TerminalPredictiveEchoSetting {
    public nonisolated init() {}
}
