/// Opens what a palette query names (`PaletteQueryTarget`), for the Open and
/// Ask Agent rows of Cmd-P and Cmd-Shift-P. The App implements it.
public protocol PaletteGoToSource: AnyObject {
    /// The focused pane's folder, for relative paths; nil when it has none.
    func baseDirectory() -> String?
    /// Opens `target`: a file in a file tab, a folder in a new terminal tab
    /// there, a web address in a browser tab.
    func open(_ target: PaletteQueryTarget)
    /// Starts a new agent chat about `target`. With `prompt` the chat sends
    /// it at once; without, the place waits in the composer for the user's words.
    func askAgent(about target: PaletteQueryTarget, prompt: String?)
}
