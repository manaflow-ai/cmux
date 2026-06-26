extension SSHConfigParser {
    /// The matching context a directive was seen in: a conjunction of `Host`
    /// condition sets that must ALL match, or an unevaluable `Match` block.
    ///
    /// Conditions compound across conditional includes. A `Host` line inside a
    /// file `Include`d under `Host work` carries both `work` and its own
    /// patterns, so its directives reach only hosts in the intersection — the
    /// way ssh reads that include only for work-matching targets.
    enum Scope {
        /// A conjunction of `Host`-line condition sets; an alias matches only if
        /// it matches every set. `[]` matches every host (global).
        case conditions([[HostPattern]])
        /// A `Match` block (or anything we cannot evaluate statically); never
        /// matches, and contributes no aliases.
        case ignored
    }
}
