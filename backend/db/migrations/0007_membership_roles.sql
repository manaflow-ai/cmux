-- phase: contract
-- contract: widen memberships_role_check to the five team roles (billing, guest); relaxing only, old code writes a subset
-- Team roles (cx-3bi.4, spec H12): memberships.role gains `billing` and `guest`. Widening the check
-- only accepts more rows, so deployed code survives it; it is a contract migration only because the
-- old constraint is dropped. Until it runs, TeamDO's membership.upsert rows for a billing or guest
-- member dead-letter in the projection (replayable); TeamDO stays the source of truth.
ALTER TABLE memberships DROP CONSTRAINT memberships_role_check;
ALTER TABLE memberships ADD CONSTRAINT memberships_role_check CHECK (role = ANY (ARRAY['owner'::text, 'admin'::text, 'member'::text, 'billing'::text, 'guest'::text])) NOT VALID;
ALTER TABLE memberships VALIDATE CONSTRAINT memberships_role_check;
