-- phase: expand
-- Documents the projection tables in the database itself (no data or shape change).
COMMENT ON TABLE users IS 'Projection of UserDO (cmux-next backend outbox); written only by outbox drains.';
COMMENT ON TABLE teams IS 'Projection of TeamDO; written only by outbox drains.';
COMMENT ON TABLE memberships IS 'Projection of TeamDO members; written only by outbox drains.';
COMMENT ON TABLE installs IS 'Projection of UserDO installs; written only by outbox drains.';
COMMENT ON TABLE hosts IS 'Projection of the TeamDO host directory; written only by outbox drains.';
