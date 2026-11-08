struct SimulatorAXWireStatus: Decodable {
    let reduceMotion: String
    let showBorders: String
    let reduceTransparency: String
    let voiceOver: String
    let colorFilter: String
    let liquidGlass: String

    enum CodingKeys: String, CodingKey {
        case reduceMotion = "reduce-motion"
        case showBorders = "show-borders"
        case reduceTransparency = "reduce-transparency"
        case voiceOver = "voiceover"
        case colorFilter = "color-filter"
        case liquidGlass = "liquid-glass"
    }
}
