import Foundation

/// Quit sheet text (Resources/Quit.xcstrings).
enum QuitStrings {
    static var title: String {
        String(localized: "quit.title", defaultValue: "Quit cmux?", table: "Quit", bundle: .module)
    }

    static var body: String {
        String(localized: "quit.body",
               defaultValue: "Your terminals run in the background in cmux-tui, so they keep running after cmux quits. Keep them to reopen cmux and continue where you left off, or end them all now.",
               table: "Quit", bundle: .module)
    }

    static var terminals: String {
        String(localized: "quit.stat.terminals", defaultValue: "Terminals", table: "Quit", bundle: .module)
    }

    static var runningPrograms: String {
        String(localized: "quit.stat.running", defaultValue: "Running programs", table: "Quit", bundle: .module)
    }

    static func busiest(_ programs: String) -> String {
        String(localized: "quit.busiest", defaultValue: "Busiest: \(programs)", table: "Quit", bundle: .module)
    }

    static func incognito(_ programs: String) -> String {
        String(localized: "quit.incognito.body",
               defaultValue: "Incognito windows close either way: \(programs) end and their browser data is deleted.",
               table: "Quit", bundle: .module)
    }

    static var remote: String {
        String(localized: "quit.remote", defaultValue: "Sessions on other machines are not affected.", table: "Quit", bundle: .module)
    }

    static var dontAskAgain: String {
        String(localized: "quit.dontAskAgain", defaultValue: "Don’t ask again", table: "Quit", bundle: .module)
    }

    static var dontAskAgainHelp: String {
        String(localized: "quit.dontAskAgain.help", defaultValue: "Change this later in Settings > General.", table: "Quit", bundle: .module)
    }

    static var keep: String {
        String(localized: "quit.button.keep", defaultValue: "Keep Sessions Running", table: "Quit", bundle: .module)
    }

    static var end: String {
        String(localized: "quit.button.end", defaultValue: "End All Sessions", table: "Quit", bundle: .module)
    }
}
