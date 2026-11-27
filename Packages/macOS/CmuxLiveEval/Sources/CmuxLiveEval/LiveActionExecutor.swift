import CmuxSwiftRender
import SwiftSyntax

/// Executes the statements of an interpreted action closure (a Button
/// action), mutating observable state boxes through ``LiveStateAccessor``s.
///
/// Supported statements: assignments (`=`, `+=`, `-=`) whose target resolves
/// to state, and mutating method calls on state (`rows.shuffle()`,
/// `items.append(x)`, `flag.toggle()`). Anything else is ignored, matching
/// the interpreter's skip-what-you-don't-understand posture.
@MainActor
struct LiveActionExecutor {
    let engine: LiveEvalEngine

    func execute(_ closure: ClosureExprSyntax, _ scope: LiveScope) {
        for item in closure.statements {
            executeStatement(item, scope)
        }
    }

    private func executeStatement(_ item: CodeBlockItemSyntax, _ scope: LiveScope) {
        guard let expression = item.item.as(ExprSyntax.self) else { return }
        if let infix = expression.as(InfixOperatorExprSyntax.self) {
            executeAssignment(infix, scope)
            return
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            executeMutatingCall(call, scope)
        }
    }

    private func executeAssignment(_ infix: InfixOperatorExprSyntax, _ scope: LiveScope) {
        let operatorText: String
        if infix.operator.is(AssignmentExprSyntax.self) {
            operatorText = "="
        } else if let binary = infix.operator.as(BinaryOperatorExprSyntax.self) {
            operatorText = binary.operator.text
        } else {
            return
        }
        guard let target = LiveStateAccessor.resolveAssignable(infix.leftOperand, scope),
              let operand = engine.expressions.eval(infix.rightOperand, engine.makeEnvironment(scope))
        else { return }
        switch operatorText {
        case "=":
            target.setValue(operand)
        case "+=":
            if let combined = Self.combined(target.currentValue(), operand, sign: 1) {
                target.setValue(combined)
            }
        case "-=":
            if let combined = Self.combined(target.currentValue(), operand, sign: -1) {
                target.setValue(combined)
            }
        default:
            break
        }
    }

    private func executeMutatingCall(_ call: FunctionCallExprSyntax, _ scope: LiveScope) {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = member.base,
              let target = LiveStateAccessor.resolveAssignable(base, scope)
        else { return }
        switch member.declName.baseName.text {
        case "shuffle":
            guard case var .array(values) = target.currentValue() else { return }
            var generator = engine.random
            values.shuffle(using: &generator)
            engine.random = generator
            target.setValue(.array(values))
        case "append":
            guard case var .array(values) = target.currentValue(),
                  let argumentExpression = call.arguments.first?.expression,
                  let argument = engine.expressions.eval(argumentExpression, engine.makeEnvironment(scope))
            else { return }
            values.append(argument)
            target.setValue(.array(values))
        case "toggle":
            target.setValue(.bool(!(target.currentValue()?.isTruthy ?? false)))
        default:
            break
        }
    }

    /// `current + sign * operand` for ints/doubles; string concatenation for
    /// `+=` on strings.
    private static func combined(_ current: SwiftValue?, _ operand: SwiftValue, sign: Int) -> SwiftValue? {
        switch (current, operand) {
        case let (.int(lhs), .int(rhs)):
            return .int(lhs + sign * rhs)
        case let (.double(lhs), .double(rhs)):
            return .double(lhs + Double(sign) * rhs)
        case let (.double(lhs), .int(rhs)):
            return .double(lhs + Double(sign * rhs))
        case let (.int(lhs), .double(rhs)):
            return .double(Double(lhs) + Double(sign) * rhs)
        case let (.string(lhs), .string(rhs)) where sign == 1:
            return .string(lhs + rhs)
        default:
            return nil
        }
    }
}
