extension CLICommandArgumentParser {
    /// Declares one recognized option and its usage spelling.
    struct Option {
        let name: String
        let kind: Kind

        static func flag(_ name: String) -> Self {
            Self(name: name, kind: .flag)
        }

        static func value(
            _ name: String,
            _ placeholder: String,
            repeatable: Bool = false
        ) -> Self {
            Self(
                name: name,
                kind: .value(placeholder: placeholder, repeatable: repeatable)
            )
        }

        static func optionalValue(_ name: String, _ placeholder: String) -> Self {
            Self(name: name, kind: .optionalValue(placeholder: placeholder))
        }

        var usage: String {
            switch kind {
            case .flag:
                name
            case .value(let placeholder, _):
                "\(name) \(placeholder)"
            case .optionalValue(let placeholder):
                "\(name) [\(placeholder)]"
            }
        }
    }
}
