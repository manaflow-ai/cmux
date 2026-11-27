import AppKit

/// Immutable, appearance-aware colors for one file explorer style.
struct FileExplorerPalette {
    let fileIconTint: NSColor
    let folderIconTint: NSColor
    private let modifiedText: NSColor
    private let addedText: NSColor
    private let deletedText: NSColor
    private let renamedText: NSColor
    private let untrackedText: NSColor

    func gitColor(for status: GitFileStatus) -> NSColor {
        switch status {
        case .modified: modifiedText
        case .added: addedText
        case .deleted: deletedText
        case .renamed: renamedText
        case .untracked: untrackedText
        }
    }

    static let liquidGlass = FileExplorerPalette(
        fileIconTint: neutralIcon,
        folderIconTint: blueIcon,
        modifiedText: orange,
        addedText: teal,
        deletedText: red,
        renamedText: purple,
        untrackedText: neutral
    )

    static let highDensity = FileExplorerPalette(
        fileIconTint: neutralIcon,
        folderIconTint: neutralIcon,
        modifiedText: yellow,
        addedText: green,
        deletedText: red,
        renamedText: blue,
        untrackedText: neutral
    )

    static let terminalStealth = FileExplorerPalette(
        fileIconTint: terminalIcon,
        folderIconTint: terminalIcon,
        modifiedText: terminalModified,
        addedText: terminalAdded,
        deletedText: terminalDeleted,
        renamedText: terminalRenamed,
        untrackedText: terminalUntracked
    )

    static let proStudio = FileExplorerPalette(
        fileIconTint: neutralIcon,
        folderIconTint: blueIcon,
        modifiedText: yellow,
        addedText: green,
        deletedText: pink,
        renamedText: cyan,
        untrackedText: neutral
    )

    static let finder = FileExplorerPalette(
        fileIconTint: neutralIcon,
        folderIconTint: blueIcon,
        modifiedText: orange,
        addedText: green,
        deletedText: red,
        renamedText: blue,
        untrackedText: neutral
    )

    private static let orange = dynamicColor(
        name: "status.orange",
        light: (0x69, 0x29, 0x00),
        dark: (0xFF, 0xB0, 0x44)
    )
    private static let yellow = dynamicColor(
        name: "status.yellow",
        light: (0x4B, 0x3A, 0x00),
        dark: (0xF2, 0xD1, 0x5C)
    )
    private static let teal = dynamicColor(
        name: "status.teal",
        light: (0x00, 0x45, 0x3B),
        dark: (0x58, 0xD6, 0xC3)
    )
    private static let green = dynamicColor(
        name: "status.green",
        light: (0x07, 0x46, 0x16),
        dark: (0x65, 0xD8, 0x79)
    )
    private static let red = dynamicColor(
        name: "status.red",
        light: (0x7B, 0x0C, 0x1D),
        dark: (0xFF, 0x91, 0x89)
    )
    private static let purple = dynamicColor(
        name: "status.purple",
        light: (0x51, 0x28, 0x77),
        dark: (0xDD, 0x96, 0xFF)
    )
    private static let blue = dynamicColor(
        name: "status.blue",
        light: (0x04, 0x3E, 0x6E),
        dark: (0x69, 0xB7, 0xFF)
    )
    private static let pink = dynamicColor(
        name: "status.pink",
        light: (0x76, 0x10, 0x3E),
        dark: (0xFF, 0x8B, 0xC3)
    )
    private static let cyan = dynamicColor(
        name: "status.cyan",
        light: (0x00, 0x42, 0x55),
        dark: (0x62, 0xD4, 0xEE)
    )
    private static let neutral = dynamicColor(
        name: "status.neutral",
        light: (0x3C, 0x3C, 0x3C),
        dark: (0xB0, 0xB0, 0xB0)
    )

    private static let terminalModified = dynamicColor(
        name: "terminal.status.modified",
        light: (0x4C, 0x3A, 0x0C),
        dark: (0xD2, 0xB8, 0x73)
    )
    private static let terminalAdded = dynamicColor(
        name: "terminal.status.added",
        light: (0x0F, 0x46, 0x1B),
        dark: (0x83, 0xCF, 0x8A)
    )
    private static let terminalDeleted = dynamicColor(
        name: "terminal.status.deleted",
        light: (0x73, 0x1B, 0x23),
        dark: (0xF9, 0x93, 0x91)
    )
    private static let terminalRenamed = dynamicColor(
        name: "terminal.status.renamed",
        light: (0x13, 0x3E, 0x68),
        dark: (0x8D, 0xB9, 0xE5)
    )
    private static let terminalUntracked = dynamicColor(
        name: "terminal.status.untracked",
        light: (0x3C, 0x3C, 0x3C),
        dark: (0xB0, 0xB0, 0xB0)
    )

    private static let neutralIcon = dynamicColor(
        name: "icon.neutral",
        light: (0x57, 0x57, 0x57),
        dark: (0xA0, 0xA0, 0xA0)
    )
    private static let terminalIcon = dynamicColor(
        name: "terminal.icon.neutral",
        light: (0x57, 0x57, 0x57),
        dark: (0xA0, 0xA0, 0xA0)
    )
    private static let blueIcon = dynamicColor(
        name: "icon.blue",
        light: (0x07, 0x55, 0x95),
        dark: (0x69, 0xB7, 0xFF)
    )

    private static func dynamicColor(
        name: String,
        light: (Int, Int, Int),
        dark: (Int, Int, Int)
    ) -> NSColor {
        let lightColor = color(components: light)
        let darkColor = color(components: dark)
        return NSColor(name: NSColor.Name("cmux.fileExplorer.\(name)")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? darkColor
                : lightColor
        }
    }

    private static func color(components: (Int, Int, Int)) -> NSColor {
        NSColor(
            srgbRed: CGFloat(components.0) / 255,
            green: CGFloat(components.1) / 255,
            blue: CGFloat(components.2) / 255,
            alpha: 1
        )
    }
}
