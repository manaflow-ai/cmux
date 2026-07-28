package terminalbot

import (
	"context"
	"strings"

	cmux "github.com/manaflow-ai/cmux/cmux-tui/bindings/go"
)

func (bot *Bot) capture(ctx context.Context, result *Result) {
	var screen cmux.ReadScreenResult
	if err := bot.call(ctx, true, "read terminal screen", func(client *cmux.Client) error {
		var err error
		screen, err = client.ReadScreen(ctx, result.Surface)
		return err
	}); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
	} else {
		result.ScreenText = screen.Text
	}

	var probe cmux.ReadScrollbackResult
	if err := bot.call(ctx, true, "inspect scrollback length", func(client *cmux.Client) error {
		var err error
		probe, err = client.ReadScrollback(ctx, result.Surface, 0, 0)
		return err
	}); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
		return
	}

	count := bot.config.ScrollbackRows
	if probe.Total < count {
		count = probe.Total
	}
	start := probe.Total - count
	var page cmux.ReadScrollbackResult
	if err := bot.call(ctx, true, "read scrollback tail", func(client *cmux.Client) error {
		var err error
		page, err = client.ReadScrollback(ctx, result.Surface, start, count)
		return err
	}); err != nil {
		result.Warnings = append(result.Warnings, err.Error())
		return
	}
	result.Scrollback = renderRows(page.Rows)
}

func renderRows(rows []cmux.RenderRow) string {
	var text strings.Builder
	for rowIndex, row := range rows {
		if rowIndex > 0 {
			text.WriteByte('\n')
		}
		for _, run := range row.Runs {
			text.WriteString(run.Text)
		}
	}
	return text.String()
}

func appendLimited(current []byte, addition []byte, limit int) []byte {
	if limit == 0 {
		return nil
	}
	if len(addition) >= limit {
		return append(current[:0], addition[len(addition)-limit:]...)
	}
	if overflow := len(current) + len(addition) - limit; overflow > 0 {
		copy(current, current[overflow:])
		current = current[:len(current)-overflow]
	}
	return append(current, addition...)
}
