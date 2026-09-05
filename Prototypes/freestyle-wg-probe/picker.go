package main

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/gdamore/tcell/v2"
	"golang.org/x/term"
)

var errPickerCancelled = errors.New("cancelled")

func vmMatches(vm cloudVM, query string) bool {
	if query == "" {
		return true
	}
	query = strings.ToLower(query)
	for _, value := range []string{vmLabel(vm), vm.ID, vm.Slug, vm.Name, chooseNetworkIP(vm)} {
		if strings.Contains(strings.ToLower(value), query) {
			return true
		}
	}
	return false
}

func chooseNetworkIP(vm cloudVM) string {
	n, ok := chooseNetwork(vm)
	if !ok {
		return ""
	}
	return n.IPv4
}

func filteredVMs(vms []cloudVM, query string) []cloudVM {
	filtered := make([]cloudVM, 0, len(vms))
	for _, vm := range vms {
		if vmMatches(vm, query) {
			filtered = append(filtered, vm)
		}
	}
	return filtered
}

func runVMTPicker(vms []cloudVM) (cloudVM, error) {
	screen, err := tcell.NewScreen()
	if err != nil {
		return cloudVM{}, err
	}
	if err := screen.Init(); err != nil {
		return cloudVM{}, err
	}
	defer screen.Fini()
	screen.HideCursor()

	query := ""
	selected := 0
	for {
		matches := filteredVMs(vms, query)
		if selected >= len(matches) {
			selected = len(matches) - 1
		}
		if selected < 0 {
			selected = 0
		}
		renderVMTPicker(screen, matches, query, selected)

		event := screen.PollEvent()
		switch event := event.(type) {
		case *tcell.EventKey:
			switch event.Key() {
			case tcell.KeyCtrlC:
				return cloudVM{}, errPickerCancelled
			case tcell.KeyEscape:
				if query == "" {
					return cloudVM{}, errPickerCancelled
				}
				query = ""
				selected = 0
			case tcell.KeyEnter:
				if len(matches) == 0 {
					continue
				}
				return matches[selected], nil
			case tcell.KeyUp:
				selected--
			case tcell.KeyDown:
				selected++
			case tcell.KeyPgUp:
				selected -= pickerPageSize(screen)
			case tcell.KeyPgDn:
				selected += pickerPageSize(screen)
			case tcell.KeyBackspace, tcell.KeyBackspace2:
				query = dropLastRune(query)
				selected = 0
			case tcell.KeyRune:
				if event.Rune() == 'q' && query == "" {
					return cloudVM{}, errPickerCancelled
				}
				query += string(event.Rune())
				selected = 0
			}
		case *tcell.EventResize:
			screen.Sync()
		}
	}
}

func dropLastRune(value string) string {
	runes := []rune(value)
	if len(runes) == 0 {
		return ""
	}
	return string(runes[:len(runes)-1])
}

func pickerPageSize(screen tcell.Screen) int {
	_, height := screen.Size()
	if height < 12 {
		return 1
	}
	return height - 11
}

func renderVMTPicker(screen tcell.Screen, vms []cloudVM, query string, selected int) {
	width, height := screen.Size()
	screen.Clear()
	normal := tcell.StyleDefault.Foreground(tcell.ColorWhite)
	dim := tcell.StyleDefault.Foreground(tcell.ColorGray)
	title := tcell.StyleDefault.Foreground(tcell.ColorLightCyan).Bold(true)
	highlight := tcell.StyleDefault.Foreground(tcell.ColorBlack).Background(tcell.ColorLightCyan).Bold(true)
	drawPickerText(screen, 2, 1, width-4, "Freestyle private VM", title)
	drawPickerText(screen, 2, 2, width-4, "System VPN started by this tool: none", dim)
	drawPickerText(screen, 2, 3, width-4, "OS routes changed by this tool: none", dim)
	drawPickerText(screen, 2, 4, width-4, "WireGuard: running inside this process only", dim)
	drawPickerText(screen, 2, 5, width-4, "Existing VPNs: left running   (for example, Tailscale)", dim)
	drawPickerText(screen, 2, 6, width-4, "↑ ↓ choose   type to filter   Enter connect   Esc clear   q quit", dim)
	drawPickerText(screen, 2, 7, width-4, "Filter: "+query+"_", normal)

	listTop := 9
	listRows := height - listTop - 2
	if listRows < 1 {
		listRows = 1
	}
	start := 0
	if selected >= listRows {
		start = selected - listRows + 1
	}
	for row := 0; row < listRows && start+row < len(vms); row++ {
		vm := vms[start+row]
		network, _ := chooseNetwork(vm)
		state := vm.State
		if state == "" {
			state = "unknown"
		}
		line := fmt.Sprintf("%-28s %-9s %s", vmLabel(vm), state, network.IPv4)
		style := normal
		if start+row == selected {
			style = highlight
		}
		drawPickerText(screen, 2, listTop+row, width-4, line, style)
	}
	if len(vms) == 0 {
		drawPickerText(screen, 2, listTop, width-4, "No matching VMs", dim)
	}
	footer := fmt.Sprintf("%d VM(s)", len(vms))
	if len(vms) > 0 {
		footer = fmt.Sprintf("%d VM(s)   selected %d", len(vms), selected+1)
	}
	drawPickerText(screen, 2, height-1, width-4, footer, dim)
	screen.ShowCursor(2+pickerTextWidth("Filter: "+query), 7)
	screen.Sync()
}

func drawPickerText(screen tcell.Screen, x, y, maxWidth int, value string, style tcell.Style) {
	width, _ := screen.Size()
	if y < 0 || x >= width || maxWidth <= 0 {
		return
	}
	column := x
	for _, r := range value {
		if column >= x+maxWidth || column >= width {
			break
		}
		screen.SetContent(column, y, r, nil, style)
		column++
	}
}

func pickerTextWidth(value string) int { return len([]rune(value)) }

func useInteractivePicker() bool {
	return term.IsTerminal(int(os.Stdin.Fd())) && term.IsTerminal(int(os.Stdout.Fd()))
}
