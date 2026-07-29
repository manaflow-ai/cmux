package terminalbot

import (
	"fmt"
	"strings"
)

func completionScript(argv []string, marker string) string {
	quoted := make([]string, len(argv))
	for index, argument := range argv {
		quoted[index] = shellQuote(argument)
	}
	return fmt.Sprintf(
		"%s; cmux_bot_status=$?; printf '\\n%s:%%d\\n' \"$cmux_bot_status\"; exit \"$cmux_bot_status\"",
		strings.Join(quoted, " "),
		marker,
	)
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
