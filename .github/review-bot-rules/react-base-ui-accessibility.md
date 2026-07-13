# React Base UI Accessibility

Apply this rule to React UI changes, especially custom interactive controls in `web/**/*.tsx` and `web/**/*.jsx`.

## Fail

- A custom dialog, popover, menu, context menu, checkbox, select, switch, tabs, tooltip, combobox, command menu, or other composite widget is built from raw `div`/`span` elements, ad hoc ARIA, `tabIndex`, or hand-rolled keyboard handlers when `@base-ui-components/react` or an existing local component already provides the relevant primitive.
- A custom control reimplements focus trapping, roving focus, escape/outside-click dismissal, typeahead, arrow-key navigation, selection state, or checked/disabled semantics that Base UI or a shared local wrapper would own.
- A new reusable React component wraps a Base UI primitive but drops required labels, keyboard behavior, controlled/uncontrolled state, focus restoration, or disabled/loading semantics.

## Pass

- Native semantic elements are sufficient, such as `button`, `a`, `input`, `select`, `textarea`, `details`, or `summary`, and the control does not need composite-widget behavior.
- The repo has no relevant Base UI primitive or shared local component, and the PR includes the required semantics, keyboard behavior, focus management, and tests or a clear manual proof.
- Existing custom UI is touched incidentally without worsening accessibility or keyboard behavior.

## Report

When this rule fails, name the exact file and line, identify the relevant Base UI primitive or local component, explain the missing accessibility or keyboard invariant, and suggest the smallest source-of-truth replacement.
