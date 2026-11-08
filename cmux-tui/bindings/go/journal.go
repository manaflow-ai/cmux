package cmux

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

const (
	maxJournalComponentBytes = 64
	maxJournalKindBytes      = 128
	maxJournalEventIDBytes   = 128
	maxJournalManifestBytes  = 1024 * 1024
	maxJournalProducerCount  = 1024
)

func validJournalComponent(value string) bool {
	if !utf8.ValidString(value) || len(value) < 1 || len(value) > maxJournalComponentBytes {
		return false
	}
	for index, character := range []byte(value) {
		if index == 0 {
			if !((character >= 'a' && character <= 'z') || (character >= '0' && character <= '9')) {
				return false
			}
			continue
		}
		if !((character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') || character == '_' || character == '-') {
			return false
		}
	}
	return true
}

func validJournalKind(value string) bool {
	if !utf8.ValidString(value) || len(value) < 1 || len(value) > maxJournalKindBytes {
		return false
	}
	parts := strings.Split(value, ".")
	for _, part := range parts {
		if !validJournalComponent(part) {
			return false
		}
	}
	return true
}

func validJournalIdentifier(value string, maximumBytes int) bool {
	return utf8.ValidString(value) && len(value) >= 1 && len(value) <= maximumBytes
}

func journalSensitivityRank(value JournalSensitivity) (int, bool) {
	switch value {
	case JournalSensitivityPublic:
		return 0, true
	case JournalSensitivityMetadata:
		return 1, true
	case JournalSensitivitySensitive:
		return 2, true
	case JournalSensitivitySecret:
		return 3, true
	default:
		return 0, false
	}
}

func validJournalJSON(value JSONValue) error {
	if _, err := json.Marshal(value); err != nil {
		return fmt.Errorf("value is not JSON: %w", err)
	}
	return nil
}

func validateJournalEventSchema(event JournalEventSchema, namespace string, maxSensitivity JournalSensitivity, seen map[string]struct{}) error {
	if !validJournalKind(event.Kind) || !strings.HasPrefix(event.Kind, namespace+".") {
		return fmt.Errorf("event kind must be a dotted name inside the producer namespace")
	}
	if event.SchemaVersion == 0 {
		return fmt.Errorf("event schema_version must be positive")
	}
	if _, ok := journalSensitivityRank(event.Sensitivity); !ok || event.Sensitivity == JournalSensitivitySecret {
		return fmt.Errorf("event sensitivity is invalid or unavailable")
	}
	maxRank, ok := journalSensitivityRank(maxSensitivity)
	eventRank, _ := journalSensitivityRank(event.Sensitivity)
	if !ok || eventRank > maxRank {
		return fmt.Errorf("event sensitivity exceeds producer authority")
	}
	if event.Class != JournalClassState && event.Class != JournalClassObservation &&
		event.Class != JournalClassEffect && event.Class != JournalClassCheckpoint {
		return fmt.Errorf("event class is invalid")
	}
	if event.Replay != JournalReplayRequired && event.Replay != JournalReplayAdvisory &&
		event.Replay != JournalReplayNever {
		return fmt.Errorf("event replay policy is invalid")
	}
	if err := validJournalJSON(event.PayloadSchema); err != nil {
		return fmt.Errorf("event payload_schema: %w", err)
	}
	identity := fmt.Sprintf("%s:%d", event.Kind, event.SchemaVersion)
	if _, exists := seen[identity]; exists {
		return fmt.Errorf("producer declares a duplicate event schema")
	}
	seen[identity] = struct{}{}
	return nil
}

// Validate checks the local shape before a manifest is sent. The daemon is
// still authoritative for JSON Schema compilation and durable state.
func (manifest JournalProducerManifest) Validate() error {
	if !validJournalComponent(manifest.ProducerID) {
		return fmt.Errorf("%w: producer_id must match [a-z0-9][a-z0-9_-]*", ErrInvalidArgument)
	}
	if manifest.Namespace != "plugin."+manifest.ProducerID {
		return fmt.Errorf("%w: namespace must equal plugin.<producer_id>", ErrInvalidArgument)
	}
	if manifest.ManifestVersion == 0 {
		return fmt.Errorf("%w: manifest_version must be positive", ErrInvalidArgument)
	}
	if manifest.MaxSensitivity == JournalSensitivitySecret {
		return fmt.Errorf("%w: secret journal payload storage is unavailable", ErrInvalidArgument)
	}
	if _, ok := journalSensitivityRank(manifest.MaxSensitivity); !ok {
		return fmt.Errorf("%w: max_sensitivity is invalid", ErrInvalidArgument)
	}
	if len(manifest.Permissions) < 1 || len(manifest.Permissions) > 32 {
		return fmt.Errorf("%w: permissions must contain 1 to 32 entries", ErrInvalidArgument)
	}
	requiredPermission := "journal.append." + manifest.Namespace
	hasPermission := false
	for _, permission := range manifest.Permissions {
		if !utf8.ValidString(permission) || len(permission) < 1 || len(permission) > 128 {
			return fmt.Errorf("%w: journal permission must contain 1 to 128 UTF-8 bytes", ErrInvalidArgument)
		}
		if permission == requiredPermission {
			hasPermission = true
		}
	}
	if !hasPermission {
		return fmt.Errorf("%w: permissions must include %s", ErrInvalidArgument, requiredPermission)
	}
	if len(manifest.Events) < 1 || len(manifest.Events) > 64 {
		return fmt.Errorf("%w: events must contain 1 to 64 entries", ErrInvalidArgument)
	}
	seen := make(map[string]struct{}, len(manifest.Events))
	for _, event := range manifest.Events {
		if err := validateJournalEventSchema(event, manifest.Namespace, manifest.MaxSensitivity, seen); err != nil {
			return fmt.Errorf("%w: %v", ErrInvalidArgument, err)
		}
	}
	encoded, err := json.Marshal(manifest)
	if err != nil {
		return fmt.Errorf("%w: manifest is not encodable: %v", ErrInvalidArgument, err)
	}
	if len(encoded) > maxJournalManifestBytes {
		return fmt.Errorf("%w: manifest exceeds %d bytes", ErrInvalidArgument, maxJournalManifestBytes)
	}
	return nil
}

// Validate checks the local shape of one event envelope. The installed
// manifest remains authoritative for its event schema and sensitivity.
func (event JournalIngress) Validate() error {
	if !validJournalComponent(event.ProducerID) {
		return fmt.Errorf("%w: producer_id is invalid", ErrInvalidArgument)
	}
	if event.ManifestVersion == 0 || event.SchemaVersion == 0 {
		return fmt.Errorf("%w: manifest_version and schema_version must be positive", ErrInvalidArgument)
	}
	if !validJournalKind(event.Kind) {
		return fmt.Errorf("%w: kind must be a dotted lowercase name", ErrInvalidArgument)
	}
	if !strings.HasPrefix(event.Kind, "plugin."+event.ProducerID+".") {
		return fmt.Errorf("%w: kind must be inside the producer namespace", ErrInvalidArgument)
	}
	if len(event.Subjects) > 64 {
		return fmt.Errorf("%w: subjects must contain at most 64 entries", ErrInvalidArgument)
	}
	for _, subject := range event.Subjects {
		if !validJournalComponent(subject.Kind) || !utf8.ValidString(subject.ID) || len(subject.ID) < 1 || len(subject.ID) > 512 {
			return fmt.Errorf("%w: journal subject is invalid", ErrInvalidArgument)
		}
	}
	if event.Sensitivity != nil {
		if _, ok := journalSensitivityRank(*event.Sensitivity); !ok || *event.Sensitivity == JournalSensitivitySecret {
			return fmt.Errorf("%w: sensitivity is invalid or unavailable", ErrInvalidArgument)
		}
	}
	for name, value := range map[string]*string{
		"causation_id":   event.CausationID,
		"correlation_id": event.CorrelationID,
	} {
		if value != nil && (!utf8.ValidString(*value) || len(*value) < 1 || len(*value) > 128) {
			return fmt.Errorf("%w: %s must contain 1 to 128 UTF-8 bytes", ErrInvalidArgument, name)
		}
	}
	if err := validJournalJSON(event.Payload); err != nil {
		return fmt.Errorf("%w: payload: %v", ErrInvalidArgument, err)
	}
	return nil
}

func validateDecodedJournalEvent(event JournalEventSchema) error {
	if !validJournalKind(event.Kind) || event.SchemaVersion == 0 {
		return fmt.Errorf("journal event schema is invalid")
	}
	if event.Class != JournalClassState && event.Class != JournalClassObservation &&
		event.Class != JournalClassEffect && event.Class != JournalClassCheckpoint {
		return fmt.Errorf("journal event class is invalid")
	}
	if event.Replay != JournalReplayRequired && event.Replay != JournalReplayAdvisory && event.Replay != JournalReplayNever {
		return fmt.Errorf("journal event replay policy is invalid")
	}
	if _, ok := journalSensitivityRank(event.Sensitivity); !ok {
		return fmt.Errorf("journal event sensitivity is invalid")
	}
	return validJournalJSON(event.PayloadSchema)
}

func validateDecodedJournalManifest(manifest JournalProducerManifest) error {
	if err := manifest.Validate(); err != nil {
		return err
	}
	return nil
}
