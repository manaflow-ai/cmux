import Foundation

/// Static cmux light/dark appearance sent to Pierre before highlighting starts.
struct MobileDiffAppearance: Sendable {
    var jsonObject: [String: Any] {
        [
            "backgroundOpacity": 1,
            "fontFamily": "Menlo",
            "fontSize": 10,
            "lineHeight": 20,
            "diffHeaderHeight": 44,
            "theme": [
                "light": "cmux-ghostty-light",
                "dark": "cmux-ghostty-dark",
            ],
            "themes": [
                "light": theme(
                    name: "cmux-ghostty-light",
                    ghosttyName: "Apple System Colors Light",
                    type: "light",
                    background: "#feffff",
                    foreground: "#000000",
                    selectionBackground: "#abd8ff",
                    selectionForeground: "#000000",
                    palette: lightPalette
                ),
                "dark": theme(
                    name: "cmux-ghostty-dark",
                    ghosttyName: "Apple System Colors",
                    type: "dark",
                    background: "#1e1e1e",
                    foreground: "#ffffff",
                    selectionBackground: "#3f638b",
                    selectionForeground: "#ffffff",
                    palette: darkPalette
                ),
            ],
        ]
    }

    private var lightPalette: [String: String] {
        basePalette.merging([
            "11": "#e5bc00",
            "14": "#69c9f2",
        ]) { _, new in new }
    }

    private var darkPalette: [String: String] {
        basePalette.merging([
            "11": "#ffd60a",
            "14": "#76d6ff",
        ]) { _, new in new }
    }

    private var basePalette: [String: String] {
        [
            "0": "#1a1a1a", "1": "#cc372e", "2": "#26a439", "3": "#cdac08",
            "4": "#0869cb", "5": "#9647bf", "6": "#479ec2", "7": "#98989d",
            "8": "#464646", "9": "#ff453a", "10": "#32d74b", "12": "#0a84ff",
            "13": "#bf5af2", "15": "#ffffff",
        ]
    }

    private func theme(
        name: String,
        ghosttyName: String,
        type: String,
        background: String,
        foreground: String,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String: String]
    ) -> [String: Any] {
        [
            "name": name,
            "ghosttyName": ghosttyName,
            "type": type,
            "background": background,
            "foreground": foreground,
            "selectionBackground": selectionBackground,
            "selectionForeground": selectionForeground,
            "palette": palette,
        ]
    }
}
