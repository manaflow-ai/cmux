extension CLICommandArgumentParser {
    /// Controls when option parsing stops for a command.
    enum OptionParsing {
        /// Options and positionals may be interspersed until a bare `--`.
        case interspersed

        /// The first positional starts a pass-through tail. A later bare `--`
        /// still separates pre-terminator tokens from explicit pass-through
        /// arguments so callers can diagnose an ambiguous mixed form.
        case beforeFirstPositional
    }
}
