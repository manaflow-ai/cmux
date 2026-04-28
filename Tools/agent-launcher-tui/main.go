package main

import (
	"bytes"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/charmbracelet/bubbles/textarea"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

type config struct {
	cmuxPath    string
	socketPath  string
	password    string
	basePath    string
	name        string
	prompt      string
	placement   string
	isolation   string
	command     string
	imagePaths  []string
	jsonOutput  bool
	useAIName   bool
	claudeCount int
	codexCount  int
	openCount   int
	customCount int
}

type stringList []string

type imageAttachment struct {
	Token string
	Path  string
	Name  string
}

type focusMode int

const (
	focusPrompt focusMode = iota
	focusConfig
)

const (
	inputLeftInset  = 2
	inputRightInset = 1
)

type model struct {
	cfg             config
	textarea        textarea.Model
	width           int
	height          int
	focus           focusMode
	selectedConfig  int
	images          []imageAttachment
	status          string
	statusKind      string
	pendingLaunches int
}

type placementOption struct {
	value string
	label string
	help  string
}

type isolationOption struct {
	value string
	label string
	help  string
}

type layoutMetrics struct {
	contentX int
	contentY int
	width    int
	logoH    int
	inputY   int
	inputH   int
	configY  int
	helpY    int
}

type launchDoneMsg struct {
	output string
	err    error
}

type tokenRange struct {
	rawStart int
	rawEnd   int
	value    string
}

var imageTokenRE = regexp.MustCompile(`\[Image #[0-9]+\]`)

var imageExtensions = map[string]bool{
	".avif": true,
	".bmp":  true,
	".gif":  true,
	".heic": true,
	".heif": true,
	".jpeg": true,
	".jpg":  true,
	".png":  true,
	".tif":  true,
	".tiff": true,
	".webp": true,
}

var placementOptions = []placementOption{
	{value: "splits", label: "Splits", help: "one workspace, split panes"},
	{value: "tabs", label: "Tabs", help: "one workspace, surface tabs"},
	{value: "workspaces", label: "Workspaces", help: "one workspace per agent"},
}

var isolationOptions = []isolationOption{
	{value: "auto", label: "Auto", help: "worktrees in git, cwd elsewhere"},
	{value: "shared", label: "Shared", help: "all agents use current directory"},
	{value: "worktrees", label: "Worktrees", help: "require git worktrees"},
}

var (
	cmuxC1    = lipgloss.AdaptiveColor{Light: "#007EA7", Dark: "#00D4FF"}
	cmuxC2    = lipgloss.AdaptiveColor{Light: "#0877B8", Dark: "#18B5FA"}
	cmuxC3    = lipgloss.AdaptiveColor{Light: "#116FC5", Dark: "#3096F5"}
	cmuxC4    = lipgloss.AdaptiveColor{Light: "#2A63D7", Dark: "#4877F1"}
	cmuxC5    = lipgloss.AdaptiveColor{Light: "#4B55DC", Dark: "#6058EF"}
	cmuxC6    = lipgloss.AdaptiveColor{Light: "#6045D0", Dark: "#6E49EE"}
	cmuxC7    = lipgloss.AdaptiveColor{Light: "#6D36B8", Dark: "#7C3AED"}
	blue      = cmuxC3
	text      = lipgloss.AdaptiveColor{Light: "#1D2533", Dark: "#DDE4EF"}
	inputText = lipgloss.AdaptiveColor{Light: "#0F172A", Dark: "#F7FAFF"}
	muted     = lipgloss.AdaptiveColor{Light: "#626C7C", Dark: "#9AA5B8"}
	dim       = lipgloss.AdaptiveColor{Light: "#8A93A3", Dark: "#6F7888"}
	red       = lipgloss.AdaptiveColor{Light: "#B42318", Dark: "#F87171"}
	inputBG   = lipgloss.AdaptiveColor{Light: "#EDF1F6", Dark: "#2A2F37"}
	subtle    = lipgloss.NewStyle().Foreground(muted)
	dimText   = lipgloss.NewStyle().Foreground(dim)
	hot       = lipgloss.NewStyle().Foreground(blue)
	errorText = lipgloss.NewStyle().Foreground(red)
	selected  = lipgloss.NewStyle().Foreground(cmuxC2)
)

func main() {
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(termenv.HasDarkBackground())
	cfg := parseConfig()
	m := initialModel(cfg)
	if _, err := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run(); err != nil {
		fmt.Fprintf(os.Stderr, "cmux-agent-launcher-tui: %v\n", err)
		os.Exit(1)
	}
}

func parseConfig() config {
	cfg := config{
		cmuxPath:    "cmux",
		placement:   "splits",
		isolation:   "auto",
		useAIName:   true,
		claudeCount: 1,
		codexCount:  1,
		openCount:   0,
		customCount: 0,
	}
	var imagePaths stringList
	flag.StringVar(&cfg.cmuxPath, "cmux", cfg.cmuxPath, "cmux executable path")
	flag.StringVar(&cfg.socketPath, "socket", "", "cmux socket path")
	flag.StringVar(&cfg.password, "password", "", "cmux socket password")
	flag.StringVar(&cfg.basePath, "base", "", "repo or hq path")
	flag.StringVar(&cfg.name, "name", "", "workspace name")
	flag.StringVar(&cfg.prompt, "prompt", "", "initial prompt")
	flag.StringVar(&cfg.placement, "placement", cfg.placement, "splits, tabs, or workspaces")
	flag.StringVar(&cfg.isolation, "isolation", cfg.isolation, "auto, shared, or worktrees")
	flag.StringVar(&cfg.command, "command", "", "custom bash command")
	flag.Var(&imagePaths, "image", "initial image path")
	flag.IntVar(&cfg.claudeCount, "claude", cfg.claudeCount, "Claude pane count")
	flag.IntVar(&cfg.codexCount, "codex", cfg.codexCount, "Codex pane count")
	flag.IntVar(&cfg.openCount, "opencode", cfg.openCount, "OpenCode pane count")
	flag.IntVar(&cfg.customCount, "custom", cfg.customCount, "custom bash pane count")
	flag.BoolVar(&cfg.jsonOutput, "json", false, "request JSON backend output")
	noAIName := flag.Bool("no-ai-name", false, "disable AI workspace name generation")
	noWorktrees := flag.Bool("no-worktrees", false, "use the current directory without git worktrees")
	worktrees := flag.Bool("worktrees", false, "require git worktrees")
	flag.Parse()
	cfg.useAIName = !*noAIName
	cfg.claudeCount = clampInt(cfg.claudeCount, 0, 8)
	cfg.codexCount = clampInt(cfg.codexCount, 0, 8)
	cfg.openCount = clampInt(cfg.openCount, 0, 8)
	cfg.customCount = clampInt(cfg.customCount, 0, 8)
	cfg.placement = normalizePlacement(cfg.placement)
	cfg.isolation = normalizeIsolation(cfg.isolation)
	if *noWorktrees {
		cfg.isolation = "shared"
	}
	if *worktrees {
		cfg.isolation = "worktrees"
	}
	cfg.imagePaths = append([]string(nil), imagePaths...)
	return cfg
}

func (l *stringList) String() string {
	if l == nil {
		return ""
	}
	return strings.Join(*l, ",")
}

func (l *stringList) Set(value string) error {
	*l = append(*l, value)
	return nil
}

func initialModel(cfg config) model {
	ta := textarea.New()
	ta.Placeholder = "What should the agents work on?"
	ta.Prompt = ""
	ta.ShowLineNumbers = false
	ta.CharLimit = 20000
	ta.SetWidth(68)
	ta.SetHeight(8)
	ta.FocusedStyle.CursorLine = lipgloss.NewStyle().Background(inputBG)
	ta.FocusedStyle.Prompt = lipgloss.NewStyle().Foreground(blue).Background(inputBG)
	ta.FocusedStyle.Text = lipgloss.NewStyle().Foreground(inputText).Background(inputBG)
	ta.FocusedStyle.Placeholder = lipgloss.NewStyle().Foreground(muted).Background(inputBG)
	ta.FocusedStyle.Base = lipgloss.NewStyle().Foreground(inputText).Background(inputBG)
	ta.FocusedStyle.EndOfBuffer = lipgloss.NewStyle().Foreground(inputBG).Background(inputBG)
	ta.BlurredStyle = ta.FocusedStyle
	ta.Focus()

	m := model{
		cfg:      cfg,
		textarea: ta,
		status:   "ready",
	}
	if strings.TrimSpace(cfg.prompt) != "" {
		m.textarea.SetValue(cfg.prompt)
	}
	for _, rawPath := range cfg.imagePaths {
		path, ok := normalizeImagePath(rawPath)
		if !ok {
			continue
		}
		token := m.imageTokenForPath(path)
		if !strings.Contains(m.textarea.Value(), token) {
			if strings.TrimSpace(m.textarea.Value()) != "" {
				m.textarea.InsertString(" ")
			}
			m.textarea.InsertString(token)
		}
	}
	return m
}

func (m model) Init() tea.Cmd {
	return textarea.Blink
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.resize(msg.Width, msg.Height)
		return m, nil
	case launchDoneMsg:
		if m.pendingLaunches > 0 {
			m.pendingLaunches--
		}
		if msg.err != nil {
			m.statusKind = "error"
			m.status = strings.TrimSpace(msg.output)
			if m.status == "" {
				m.status = msg.err.Error()
			}
			return m, nil
		}
		m.statusKind = "ok"
		m.status = firstNonEmptyLine(msg.output)
		if m.status == "" {
			m.status = "workspace created"
		}
		return m, nil
	case tea.MouseMsg:
		if msg.Action != tea.MouseActionPress {
			return m, nil
		}
		return m.handleMouse(msg)
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "ctrl+r", "enter":
			return m.startLaunch()
		case "shift+enter", "alt+enter", "ctrl+j":
			if m.focus != focusPrompt {
				m.focus = focusPrompt
				cmd = m.textarea.Focus()
			}
			m.textarea.InsertString("\n")
			return m, cmd
		case "tab":
			m.toggleFocus()
			return m, nil
		}

		if m.focus == focusConfig {
			switch msg.String() {
			case "up", "k":
				m.moveSelectedConfig(-1)
			case "down", "j":
				m.moveSelectedConfig(1)
			case "left", "h", "-":
				m.adjustSelectedConfig(-1)
			case "right", "l", "+", "=":
				m.adjustSelectedConfig(1)
			case " ":
				m.chooseSelectedPlacement()
			case "esc":
				m.focus = focusPrompt
				cmd = m.textarea.Focus()
			}
			return m, cmd
		}

		if msg.Type == tea.KeyRunes && len(msg.Runes) > 0 {
			replacement, changed := m.replaceImagePaths(string(msg.Runes))
			if changed {
				m.textarea.InsertString(replacement)
				m.normalizeImageTokenCursor("right")
				m.statusKind = "ok"
				m.status = fmt.Sprintf("attached %d image%s", len(m.images), plural(len(m.images)))
				return m, nil
			}
		}
		m.textarea, cmd = m.textarea.Update(msg)
		switch msg.String() {
		case "left", "ctrl+b", "alt+left":
			m.normalizeImageTokenCursor("left")
		case "right", "ctrl+f", "alt+right":
			m.normalizeImageTokenCursor("right")
		}
		return m, cmd
	}

	m.textarea, cmd = m.textarea.Update(msg)
	return m, cmd
}

func (m *model) resize(width, height int) {
	m.width = width
	m.height = height
	contentWidth := contentWidthForWindow(width)
	textWidth := maxInt(1, contentWidth-inputLeftInset-inputRightInset)
	textHeight := clampInt(height/5, 5, 8)
	m.textarea.SetWidth(textWidth)
	m.textarea.SetHeight(textHeight)
}

func (m model) metrics() layoutMetrics {
	contentWidth := contentWidthForWindow(m.width)
	inputHeight := m.textarea.Height() + 2
	logoHeight := 7
	configHeight := configLineCount()
	bodyHeight := logoHeight + 1 + inputHeight + 1 + configHeight + 1 + 3
	contentX := maxInt(0, (m.width-contentWidth)/2)
	contentY := maxInt(0, (m.height-bodyHeight)/2)
	inputY := contentY + logoHeight + 1
	configY := inputY + inputHeight + 1
	helpY := configY + configHeight + 3
	return layoutMetrics{
		contentX: contentX,
		contentY: contentY,
		width:    contentWidth,
		logoH:    logoHeight,
		inputY:   inputY,
		inputH:   inputHeight,
		configY:  configY,
		helpY:    helpY,
	}
}

func (m model) handleMouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	metrics := m.metrics()
	if msg.X < metrics.contentX || msg.X >= metrics.contentX+metrics.width {
		return m, nil
	}

	if msg.Y >= metrics.inputY && msg.Y < metrics.inputY+metrics.inputH {
		m.focus = focusPrompt
		return m, m.textarea.Focus()
	}

	if msg.Y >= metrics.configY && msg.Y < metrics.configY+configLineCount() {
		if selected, ok := configSelectionForLine(msg.Y - metrics.configY); ok {
			m.focus = focusConfig
			m.textarea.Blur()
			m.selectedConfig = selected
			relX := msg.X - metrics.contentX
			if selected < agentRowCount() {
				switch {
				case relX >= 21 && relX <= 25:
					m.adjustSelectedConfig(-1)
				case relX >= 28 && relX <= 33:
					m.adjustSelectedConfig(1)
				}
			} else {
				m.chooseSelectedPlacement()
			}
		}
		return m, nil
	}

	if msg.Y == metrics.helpY {
		return m.startLaunch()
	}

	return m, nil
}

func (m *model) toggleFocus() {
	if m.focus == focusPrompt {
		m.focus = focusConfig
		m.textarea.Blur()
		return
	}
	m.focus = focusPrompt
	m.textarea.Focus()
}

func agentRowCount() int {
	return 4
}

func placementRowStart() int {
	return agentRowCount()
}

func isolationRowStart() int {
	return placementRowStart() + len(placementOptions)
}

func configRowCount() int {
	return isolationRowStart() + len(isolationOptions)
}

func configLineCount() int {
	return agentRowCount() + len(placementOptions) + len(isolationOptions) + 5
}

func selectedPlacementOptionIndex(selected int) (int, bool) {
	index := selected - placementRowStart()
	return index, index >= 0 && index < len(placementOptions)
}

func selectedIsolationOptionIndex(selected int) (int, bool) {
	index := selected - isolationRowStart()
	return index, index >= 0 && index < len(isolationOptions)
}

func isPlacementConfigRow(selected int) bool {
	_, ok := selectedPlacementOptionIndex(selected)
	return ok
}

func isIsolationConfigRow(selected int) bool {
	_, ok := selectedIsolationOptionIndex(selected)
	return ok
}

func configSelectionForLine(line int) (int, bool) {
	placementLine := agentRowCount() + 3
	isolationLine := placementLine + len(placementOptions) + 2
	switch {
	case line >= 1 && line < 1+agentRowCount():
		return line - 1, true
	case line >= placementLine && line < placementLine+len(placementOptions):
		return placementRowStart() + line - placementLine, true
	case line >= isolationLine && line < isolationLine+len(isolationOptions):
		return isolationRowStart() + line - isolationLine, true
	default:
		return 0, false
	}
}

func (m *model) moveSelectedConfig(delta int) {
	count := configRowCount()
	m.selectedConfig = (m.selectedConfig + delta + count) % count
}

func (m *model) adjustSelectedConfig(delta int) {
	switch m.selectedConfig {
	case 0:
		m.cfg.claudeCount = clampInt(m.cfg.claudeCount+delta, 0, 8)
	case 1:
		m.cfg.codexCount = clampInt(m.cfg.codexCount+delta, 0, 8)
	case 2:
		m.cfg.openCount = clampInt(m.cfg.openCount+delta, 0, 8)
	case 3:
		m.cfg.customCount = clampInt(m.cfg.customCount+delta, 0, 8)
	default:
		if _, ok := selectedPlacementOptionIndex(m.selectedConfig); ok {
			index := placementIndex(m.cfg.placement)
			index = (index + delta + len(placementOptions)) % len(placementOptions)
			m.cfg.placement = placementOptions[index].value
			m.selectedConfig = placementRowStart() + index
			return
		}
		if _, ok := selectedIsolationOptionIndex(m.selectedConfig); ok {
			index := isolationIndex(m.cfg.isolation)
			index = (index + delta + len(isolationOptions)) % len(isolationOptions)
			m.cfg.isolation = isolationOptions[index].value
			m.selectedConfig = isolationRowStart() + index
		}
	}
}

func (m *model) chooseSelectedPlacement() {
	if index, ok := selectedPlacementOptionIndex(m.selectedConfig); ok {
		m.cfg.placement = placementOptions[index].value
		return
	}
	if index, ok := selectedIsolationOptionIndex(m.selectedConfig); ok {
		m.cfg.isolation = isolationOptions[index].value
	}
}

func (m model) startLaunch() (tea.Model, tea.Cmd) {
	prompt := strings.TrimSpace(m.textarea.Value())
	if prompt == "" && len(m.images) == 0 {
		m.statusKind = "error"
		m.status = "write a prompt or attach an image first"
		return m, nil
	}
	if m.cfg.claudeCount+m.cfg.codexCount+m.cfg.openCount+m.cfg.customCount == 0 {
		m.cfg.claudeCount = 1
		m.cfg.codexCount = 1
	}
	m.pendingLaunches++
	m.statusKind = ""
	m.status = pendingLaunchStatus(m.pendingLaunches)
	cfg := m.cfg
	images := append([]imageAttachment(nil), m.images...)
	m.textarea.Reset()
	m.images = nil
	m.focus = focusPrompt
	focusCmd := m.textarea.Focus()
	launchCmd := func() tea.Msg {
		args := []string{}
		if cfg.socketPath != "" {
			args = append(args, "--socket", cfg.socketPath)
		}
		if cfg.password != "" {
			args = append(args, "--password", cfg.password)
		}
		if cfg.jsonOutput {
			args = append(args, "--json")
		}
		args = append(args,
			"home", "run",
			"--prompt", prompt,
			"--claude", strconv.Itoa(cfg.claudeCount),
			"--codex", strconv.Itoa(cfg.codexCount),
			"--opencode", strconv.Itoa(cfg.openCount),
			"--custom", strconv.Itoa(cfg.customCount),
			"--placement", cfg.placement,
			"--isolation", cfg.isolation,
		)
		if cfg.command != "" {
			args = append(args, "--command", cfg.command)
		}
		if cfg.basePath != "" {
			args = append(args, "--base", cfg.basePath)
		}
		if cfg.name != "" {
			args = append(args, "--name", cfg.name)
		}
		if !cfg.useAIName {
			args = append(args, "--no-ai-name")
		}
		for _, image := range images {
			args = append(args, "--image", image.Path)
		}
		cmd := exec.Command(cfg.cmuxPath, args...)
		var output bytes.Buffer
		cmd.Stdout = &output
		cmd.Stderr = &output
		err := cmd.Run()
		return launchDoneMsg{output: output.String(), err: err}
	}
	return m, tea.Batch(focusCmd, launchCmd)
}

func (m model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	metrics := m.metrics()
	inputBox := m.renderInput(metrics.width)
	logo := cmuxLogo(metrics.width)
	config := m.configPanel(metrics.width)
	images := m.imageLine(metrics.width)
	status := m.statusLine(metrics.width)
	help := dimText.Width(metrics.width).Align(lipgloss.Center).Render("enter launch   shift+enter newline   tab config   click controls   ctrl+c quit")

	body := lipgloss.JoinVertical(
		lipgloss.Center,
		logo,
		"",
		inputBox,
		"",
		config,
		"",
		images,
		status,
		help,
	)
	rendered := lipgloss.NewStyle().Foreground(text).Render(body)
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, rendered)
}

func (m model) renderInput(width int) string {
	type displayLine struct {
		text        string
		placeholder bool
		cursorCol   int
		showCursor  bool
	}

	height := m.textarea.Height()
	if height <= 0 || width <= 0 {
		return ""
	}
	innerWidth := maxInt(1, width-inputLeftInset-inputRightInset)

	value := m.textarea.Value()
	cursorLine := m.textarea.Line()
	info := m.textarea.LineInfo()
	cursorRawCol := info.StartColumn + info.ColumnOffset
	lines := make([]displayLine, 0, height)
	cursorDisplayIndex := 0
	showCursor := m.focus == focusPrompt && !m.textarea.Cursor.Blink

	if value == "" {
		lines = append(lines, displayLine{
			text:        m.textarea.Placeholder,
			placeholder: true,
			cursorCol:   0,
			showCursor:  showCursor,
		})
	} else {
		rawLines := strings.Split(value, "\n")
		for lineIndex, rawLine := range rawLines {
			segments := wrapEditorLine(rawLine, innerWidth)
			for segmentIndex, segment := range segments {
				cursorCol := -1
				lineShowCursor := false
				if lineIndex == cursorLine && segmentIndex == info.RowOffset {
					cursorDisplayIndex = len(lines)
					cursorCol = clampInt(cursorRawCol-segment.start, 0, len([]rune(segment.text)))
					lineShowCursor = showCursor
				}
				lines = append(lines, displayLine{text: segment.text, cursorCol: cursorCol, showCursor: lineShowCursor})
			}
		}
	}

	start := 0
	if cursorDisplayIndex >= height {
		start = cursorDisplayIndex - height + 1
	}
	if start > len(lines) {
		start = len(lines)
	}

	visible := lines[start:]
	if len(visible) > height {
		visible = visible[:height]
	}
	for len(visible) < height {
		visible = append(visible, displayLine{cursorCol: -1})
	}

	rendered := make([]string, 0, len(visible))
	rendered = append(rendered, renderEditorBlankLine(width))
	for _, line := range visible {
		rendered = append(rendered, renderEditorInsetLine(line.text, innerWidth, line.cursorCol, line.placeholder, line.showCursor))
	}
	rendered = append(rendered, renderEditorBlankLine(width))
	return strings.Join(rendered, "\n")
}

type editorSegment struct {
	text  string
	start int
}

func wrapEditorLine(line string, width int) []editorSegment {
	if line == "" {
		return []editorSegment{{text: "", start: 0}}
	}
	runes := []rune(line)
	segments := make([]editorSegment, 0, maxInt(1, len(runes)/maxInt(1, width)))
	for start := 0; start < len(runes); {
		end := start
		lineWidth := 0
		for end < len(runes) {
			nextWidth := lipgloss.Width(string(runes[end]))
			if lineWidth > 0 && lineWidth+nextWidth > width {
				break
			}
			lineWidth += nextWidth
			end++
			if lineWidth >= width {
				break
			}
		}
		if end == start {
			end++
		}
		segments = append(segments, editorSegment{
			text:  string(runes[start:end]),
			start: start,
		})
		start = end
	}
	return segments
}

func renderEditorLine(raw string, width int, cursorCol int, placeholder bool, showCursor bool) string {
	runes := []rune(raw)
	if len(runes) > width {
		runes = runes[:width]
	}

	normalStyle := lipgloss.NewStyle().Foreground(inputText).Background(inputBG)
	placeholderStyle := lipgloss.NewStyle().Foreground(muted).Background(inputBG)
	lineStyle := normalStyle
	if placeholder {
		lineStyle = placeholderStyle
	}
	cursorStyle := lipgloss.NewStyle().Foreground(inputBG).Background(inputText)

	var out strings.Builder
	for col := 0; col < width; col++ {
		cell := " "
		if col < len(runes) {
			cell = string(runes[col])
		}
		if showCursor && col == cursorCol {
			out.WriteString(cursorStyle.Render(cell))
		} else {
			out.WriteString(lineStyle.Render(cell))
		}
	}
	return out.String()
}

func renderEditorInsetLine(raw string, innerWidth int, cursorCol int, placeholder bool, showCursor bool) string {
	cell := inputCellStyle()
	left := cell.Render(strings.Repeat(" ", inputLeftInset))
	right := cell.Render(strings.Repeat(" ", inputRightInset))
	return left + renderEditorLine(raw, innerWidth, cursorCol, placeholder, showCursor) + right
}

func renderEditorBlankLine(width int) string {
	return inputCellStyle().Render(strings.Repeat(" ", maxInt(1, width)))
}

func inputCellStyle() lipgloss.Style {
	return lipgloss.NewStyle().Foreground(inputText).Background(inputBG)
}

func cmuxLogo(width int) string {
	lines := []string{
		lipgloss.NewStyle().Foreground(cmuxC1).Render("  ::"),
		lipgloss.NewStyle().Foreground(cmuxC2).Render("    ::::") + "              " +
			lipgloss.NewStyle().Foreground(cmuxC1).Render("c") +
			lipgloss.NewStyle().Foreground(cmuxC2).Render("m") +
			lipgloss.NewStyle().Foreground(cmuxC3).Render("u") +
			lipgloss.NewStyle().Foreground(cmuxC7).Render("x"),
		lipgloss.NewStyle().Foreground(cmuxC3).Render("      ::::::"),
		lipgloss.NewStyle().Foreground(cmuxC4).Render("        ::::::") + "        " + subtle.Render("the open source terminal"),
		lipgloss.NewStyle().Foreground(cmuxC5).Render("      ::::::") + "          " + subtle.Render("built for coding agents"),
		lipgloss.NewStyle().Foreground(cmuxC6).Render("    ::::"),
		lipgloss.NewStyle().Foreground(cmuxC7).Render("  ::"),
	}
	return lipgloss.NewStyle().Width(width).Align(lipgloss.Left).Render(strings.Join(lines, "\n"))
}

func (m model) sectionTitle(label string, active bool, width int) string {
	style := subtle
	if active {
		style = hot
	}
	return style.Width(width).Align(lipgloss.Left).Render(label)
}

func (m model) configPanel(width int) string {
	lines := []string{
		m.sectionTitle("Agents", m.focus == focusConfig && m.selectedConfig < agentRowCount(), width),
		m.agentRow(0, "Claude Code", m.cfg.claudeCount),
		m.agentRow(1, "Codex", m.cfg.codexCount),
		m.agentRow(2, "OpenCode Kimi", m.cfg.openCount),
		m.agentRow(3, "Custom bash", m.cfg.customCount),
		"",
		m.sectionTitle("Placement", m.focus == focusConfig && isPlacementConfigRow(m.selectedConfig), width),
	}
	for index, option := range placementOptions {
		lines = append(lines, m.placementRow(index, option))
	}
	lines = append(lines, "", m.sectionTitle("Isolation", m.focus == focusConfig && isIsolationConfigRow(m.selectedConfig), width))
	for index, option := range isolationOptions {
		lines = append(lines, m.isolationRow(index, option))
	}
	return lipgloss.NewStyle().
		Width(width).
		Render(strings.Join(lines, "\n"))
}

func (m model) agentRow(index int, label string, count int) string {
	active := m.focus == focusConfig && m.selectedConfig == index
	prefix := " "
	if active {
		prefix = ">"
	}
	line := fmt.Sprintf("%s %-18s  [-] %d [+]", prefix, label, count)
	if active {
		return selected.Render(line)
	}
	return subtle.Render(line)
}

func (m model) placementRow(index int, option placementOption) string {
	rowIndex := placementRowStart() + index
	active := m.focus == focusConfig && m.selectedConfig == rowIndex
	chosen := m.cfg.placement == option.value
	prefix := " "
	if active {
		prefix = ">"
	}
	mark := "( )"
	if chosen {
		mark = "(*)"
	}
	line := fmt.Sprintf("%s %s %-11s %s", prefix, mark, option.label, option.help)
	if active {
		return selected.Render(line)
	}
	if chosen {
		return hot.Render(line)
	}
	return subtle.Render(line)
}

func (m model) isolationRow(index int, option isolationOption) string {
	rowIndex := isolationRowStart() + index
	active := m.focus == focusConfig && m.selectedConfig == rowIndex
	chosen := m.cfg.isolation == option.value
	prefix := " "
	if active {
		prefix = ">"
	}
	mark := "( )"
	if chosen {
		mark = "(*)"
	}
	line := fmt.Sprintf("%s %s %-11s %s", prefix, mark, option.label, option.help)
	if active {
		return selected.Render(line)
	}
	if chosen {
		return hot.Render(line)
	}
	return subtle.Render(line)
}

func (m model) imageLine(width int) string {
	if len(m.images) == 0 {
		return subtle.Width(width).Align(lipgloss.Center).Render("Images: drop or paste a file")
	}
	parts := make([]string, 0, len(m.images))
	for _, image := range m.images {
		parts = append(parts, hot.Render(image.Token)+" "+subtle.Render(image.Name))
	}
	return lipgloss.NewStyle().Width(width).Align(lipgloss.Center).Render("Images: " + strings.Join(parts, "  "))
}

func (m model) statusLine(width int) string {
	text := m.status
	if m.pendingLaunches > 0 && m.statusKind != "error" {
		text = pendingLaunchStatus(m.pendingLaunches)
	}
	style := subtle
	if m.statusKind == "error" {
		style = errorText
	} else if m.statusKind == "ok" || m.pendingLaunches > 0 {
		style = hot
	}
	if strings.TrimSpace(text) == "" {
		text = "ready"
	}
	return style.Width(width).Align(lipgloss.Center).Render(text)
}

func pendingLaunchStatus(count int) string {
	if count <= 1 {
		return "creating cmux layout in background..."
	}
	return fmt.Sprintf("creating %d cmux layouts in background...", count)
}

func (m *model) replaceImagePaths(input string) (string, bool) {
	tokens := shellTokens(input)
	if len(tokens) == 0 {
		return input, false
	}

	type replacement struct {
		start int
		end   int
		token string
	}
	var replacements []replacement
	for _, token := range tokens {
		path, ok := normalizeImagePath(token.value)
		if !ok {
			continue
		}
		replacements = append(replacements, replacement{
			start: token.rawStart,
			end:   token.rawEnd,
			token: m.imageTokenForPath(path),
		})
	}
	if len(replacements) == 0 {
		return input, false
	}

	var out strings.Builder
	last := 0
	for _, repl := range replacements {
		if repl.start < last {
			continue
		}
		out.WriteString(input[last:repl.start])
		out.WriteString(repl.token)
		last = repl.end
	}
	out.WriteString(input[last:])
	return out.String(), true
}

func (m *model) imageTokenForPath(path string) string {
	for _, image := range m.images {
		if image.Path == path {
			return image.Token
		}
	}
	token := fmt.Sprintf("[Image #%d]", len(m.images)+1)
	m.images = append(m.images, imageAttachment{
		Token: token,
		Path:  path,
		Name:  filepath.Base(path),
	})
	return token
}

func (m *model) normalizeImageTokenCursor(direction string) {
	lines := strings.Split(m.textarea.Value(), "\n")
	lineIndex := m.textarea.Line()
	if lineIndex < 0 || lineIndex >= len(lines) {
		return
	}
	line := lines[lineIndex]
	info := m.textarea.LineInfo()
	col := info.StartColumn + info.CharOffset
	for _, loc := range imageTokenRE.FindAllStringIndex(line, -1) {
		start := runeIndexAtByte(line, loc[0])
		end := runeIndexAtByte(line, loc[1])
		if col > start && col < end {
			if direction == "left" {
				m.textarea.SetCursor(start)
			} else {
				m.textarea.SetCursor(end)
			}
			return
		}
	}
}

func shellTokens(input string) []tokenRange {
	var tokens []tokenRange
	var current strings.Builder
	inToken := false
	start := 0
	quote := rune(0)
	escaping := false

	flush := func(end int) {
		if !inToken {
			return
		}
		tokens = append(tokens, tokenRange{
			rawStart: start,
			rawEnd:   end,
			value:    current.String(),
		})
		current.Reset()
		inToken = false
		quote = 0
		escaping = false
	}

	for i, r := range input {
		if !inToken && !unicode.IsSpace(r) {
			inToken = true
			start = i
		}
		if !inToken {
			continue
		}
		if escaping {
			current.WriteRune(r)
			escaping = false
			continue
		}
		if r == '\\' {
			escaping = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				current.WriteRune(r)
			}
			continue
		}
		if r == '\'' || r == '"' {
			quote = r
			continue
		}
		if unicode.IsSpace(r) {
			flush(i)
			continue
		}
		current.WriteRune(r)
	}
	flush(len(input))
	return tokens
}

func normalizeImagePath(raw string) (string, bool) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", false
	}
	if strings.HasPrefix(value, "file://") {
		parsed, err := url.Parse(value)
		if err != nil || !parsed.IsAbs() {
			return "", false
		}
		value = parsed.Path
	}
	if strings.HasPrefix(value, "~") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", false
		}
		if value == "~" {
			value = home
		} else if strings.HasPrefix(value, "~/") {
			value = filepath.Join(home, value[2:])
		}
	}
	if !filepath.IsAbs(value) {
		abs, err := filepath.Abs(value)
		if err != nil {
			return "", false
		}
		value = abs
	}
	ext := strings.ToLower(filepath.Ext(value))
	if !imageExtensions[ext] {
		return "", false
	}
	info, err := os.Stat(value)
	if err != nil || info.IsDir() {
		return "", false
	}
	clean, err := filepath.EvalSymlinks(value)
	if err == nil {
		value = clean
	}
	return filepath.Clean(value), true
}

func runeIndexAtByte(s string, byteIndex int) int {
	if byteIndex <= 0 {
		return 0
	}
	if byteIndex >= len(s) {
		return utf8.RuneCountInString(s)
	}
	return utf8.RuneCountInString(s[:byteIndex])
}

func firstNonEmptyLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return ""
}

func plural(count int) string {
	if count == 1 {
		return ""
	}
	return "s"
}

func clampInt(value, minValue, maxValue int) int {
	if value < minValue {
		return minValue
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func contentWidthForWindow(width int) int {
	boxWidth := clampInt(width-8, 68, 104)
	return clampInt(boxWidth-6, 56, 94)
}

func normalizePlacement(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "tab", "tabs":
		return "tabs"
	case "workspace", "workspaces", "separate":
		return "workspaces"
	default:
		return "splits"
	}
}

func placementIndex(value string) int {
	normalized := normalizePlacement(value)
	for index, option := range placementOptions {
		if option.value == normalized {
			return index
		}
	}
	return 0
}

func normalizeIsolation(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "shared", "cwd", "none", "off", "no-worktrees":
		return "shared"
	case "worktree", "worktrees", "required", "git":
		return "worktrees"
	default:
		return "auto"
	}
}

func isolationIndex(value string) int {
	normalized := normalizeIsolation(value)
	for index, option := range isolationOptions {
		if option.value == normalized {
			return index
		}
	}
	return 0
}
