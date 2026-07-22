package cmux

import "encoding/json"

func parseEvent(raw map[string]any) Event {
	name, _ := raw["event"].(string)
	mustDecode := func(out any) bool {
		encoded, err := json.Marshal(raw)
		if err != nil {
			return false
		}
		return json.Unmarshal(encoded, out) == nil
	}
	switch name {
	case "tree-changed":
		return TreeChangedEvent{}
	case "layout-changed":
		var event LayoutChangedEvent
		if mustDecode(&event) {
			return event
		}
	case "empty":
		return EmptyEvent{}
	case "overflow":
		var event OverflowEvent
		if mustDecode(&event) {
			return event
		}
	case "surface-output", "surface-exited", "bell":
		var event SurfaceEvent
		if mustDecode(&event) {
			return event
		}
	case "title-changed":
		var event TitleChangedEvent
		if mustDecode(&event) {
			return event
		}
	case "surface-resized":
		var event SurfaceResizedEvent
		if mustDecode(&event) {
			return event
		}
	case "surface-resize-failed":
		var event SurfaceResizeFailedEvent
		if mustDecode(&event) {
			return event
		}
	case "vt-state":
		var event VtStateEvent
		if mustDecode(&event) {
			return event
		}
	case "output":
		var event OutputEvent
		if mustDecode(&event) {
			return event
		}
	case "resized":
		if _, ok := raw["replay"]; !ok {
			if data, ok := raw["data"].(string); ok {
				raw["replay"] = data
			}
		}
		var event ResizedEvent
		if mustDecode(&event) {
			return event
		}
	case "detached":
		var event DetachedEvent
		if mustDecode(&event) {
			return event
		}
	}
	return UnknownEvent{Name: name, Raw: raw}
}
