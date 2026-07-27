package terminalbot

import (
	"bytes"
	"fmt"
	"strconv"
	"strings"
)

type completionMarker struct {
	token []byte
	tail  []byte
}

func newCompletionMarker(mutationID string) *completionMarker {
	token := "CMUX_TERMINAL_BOT_DONE_" + strings.ReplaceAll(mutationID, "-", "")
	return &completionMarker{token: []byte(token)}
}

func (marker *completionMarker) command(argv []string) string {
	quoted := make([]string, len(argv))
	for index, arg := range argv {
		quoted[index] = shellQuote(arg)
	}
	script := fmt.Sprintf(
		"%s; cmux_bot_status=$?; printf '\\n%s:%%d\\n' \"$cmux_bot_status\"; "+
			"IFS= read -r cmux_bot_ack; exit \"$cmux_bot_status\"",
		strings.Join(quoted, " "),
		marker.token,
	)
	return "exec /bin/sh -lc " + shellQuote(script) + "\n"
}

func (marker *completionMarker) consume(data []byte) (int, bool) {
	marker.tail = append(marker.tail, data...)
	needle := append(append([]byte(nil), marker.token...), ':')
	index := bytes.Index(marker.tail, needle)
	if index < 0 {
		marker.trim()
		return 0, false
	}

	start := index + len(needle)
	end := start
	for end < len(marker.tail) && marker.tail[end] >= '0' && marker.tail[end] <= '9' {
		end++
	}
	if end == start || end == len(marker.tail) {
		marker.trim()
		return 0, false
	}
	status, err := strconv.Atoi(string(marker.tail[start:end]))
	if err != nil {
		marker.trim()
		return 0, false
	}
	return status, true
}

func (marker *completionMarker) trim() {
	const retained = 4_096
	if len(marker.tail) > retained {
		marker.tail = append(marker.tail[:0], marker.tail[len(marker.tail)-retained:]...)
	}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}
