/// Response format for machine reads. Opt-in grants no session or execution rights.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MachineReadOptions {
    /// Include owner metadata and admitted remote catalog records.
    pub catalog: bool,
}
