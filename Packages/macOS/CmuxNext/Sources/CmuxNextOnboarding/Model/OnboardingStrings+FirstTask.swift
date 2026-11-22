import Foundation

extension OnboardingStrings {
    static var firstTaskTitle: String { String(localized: "onboarding.firstTask.title", defaultValue: "Try a first task", bundle: .module) }
    static var firstTaskSubtitle: String {
        String(localized: "onboarding.firstTask.subtitle", defaultValue: "Pick one. It runs for real, and you keep what it makes.", bundle: .module)
    }
    static var firstTaskWhere: String {
        String(localized: "onboarding.firstTask.where", defaultValue: "Runs with your default agent in ~/cmux/first-task.", bundle: .module)
    }
    static var firstTaskNoAgent: String {
        String(localized: "onboarding.firstTask.noAgent", defaultValue: "The agent could not start here. Skip this step and try one from a new chat later.", bundle: .module)
    }
    static var firstTaskFolderFailed: String {
        String(localized: "onboarding.firstTask.folderFailed",
               defaultValue: "cmux could not create ~/cmux/first-task. Skip this step and try a task from a new chat later.", bundle: .module)
    }
    static var firstTaskSaved: String { String(localized: "onboarding.firstTask.saved", defaultValue: "Saved files", bundle: .module) }
    static var firstTaskOpen: String { String(localized: "onboarding.firstTask.open", defaultValue: "Open", bundle: .module) }
    static var firstTaskReveal: String { String(localized: "onboarding.firstTask.reveal", defaultValue: "Show in Finder", bundle: .module) }

    static func firstTaskName(_ task: FirstTask) -> String {
        switch task {
        case .note: String(localized: "onboarding.firstTask.note.title", defaultValue: "Leave yourself a note", bundle: .module)
        case .chart: String(localized: "onboarding.firstTask.chart.title", defaultValue: "Turn a spreadsheet into a chart", bundle: .module)
        }
    }

    static func firstTaskDetail(_ task: FirstTask) -> String {
        switch task {
        case .note: String(localized: "onboarding.firstTask.note.detail", defaultValue: "A short welcome note with three tips, saved as a file.", bundle: .module)
        case .chart: String(localized: "onboarding.firstTask.chart.detail", defaultValue: "Charts a sample year of sales and saves the image.", bundle: .module)
        }
    }

    /// What the chat sends (the user's first message, so it is in their language).
    static func firstTaskPrompt(_ task: FirstTask) -> String {
        switch task {
        case .note:
            String(localized: "onboarding.firstTask.note.prompt",
                   defaultValue: "Write me a short, friendly welcome note with three tips for getting started with cmux. Save it as welcome-note.md in this folder.",
                   bundle: .module)
        case .chart:
            String(localized: "onboarding.firstTask.chart.prompt",
                   defaultValue: "Read sales.csv in this folder and make a bar chart of revenue by month. Save it as chart.svg in this folder, then tell me in one sentence what it shows.",
                   bundle: .module)
        }
    }
}
