public import CmuxNextActions

extension UpdateCommandAnswer {
    /// An update command's answer as the action's result (`action.run` `result`, or its error).
    public static func actionResult(_ answer: Task<UpdateCommandAnswer, Never>) -> ActionResultWork {
        // task-owner: the action run; ends with `answer`.
        Task {
            switch await answer.value {
            case .answered(let fields):
                .success(fields.mapValues { field in
                    switch field {
                    case .string(let text): .string(text)
                    case .bool(let flag): .bool(flag)
                    case .double(let number): .double(number)
                    }
                })
            case .refused(let reason): .failure(ActionWorkFailure(refusal: .unavailable, reason: reason))
            case .failed(let message): .failure(ActionWorkFailure(message))
            }
        }
    }
}
