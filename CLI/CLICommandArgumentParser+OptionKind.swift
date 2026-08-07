extension CLICommandArgumentParser.Option {
    /// Describes whether an option accepts a value and how often it may occur.
    enum Kind {
        case flag
        case value(placeholder: String, repeatable: Bool)
        case optionalValue(placeholder: String)
    }
}
