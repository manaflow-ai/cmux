/// Providers of one page whose items an open builds after its first frame
/// (`PaletteModel.load`): their rows are not on the empty query, so reading
/// their sources (every workspace and tab of every machine) would only delay
/// the frame.
struct PaletteDeferredLoad {
    /// The page the items load into; dropped when it left the stack.
    let state: PageState
    let providers: [any PaletteProvider]
}
