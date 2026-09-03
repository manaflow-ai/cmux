package dev.cmux.android.core.pairing

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "paired_macs")
data class PairedMacEntity(
    @PrimaryKey val macDeviceId: String,
    val displayName: String?,
    val primaryHost: String,
    val primaryPort: Int,
    val routeKind: String,
    val macUserId: String?,
    val pairedAtMs: Long = System.currentTimeMillis(),
)

@Dao
interface PairedMacDao {
    @Query("SELECT * FROM paired_macs ORDER BY pairedAtMs DESC")
    fun observeAll(): Flow<List<PairedMacEntity>>

    @Query("SELECT * FROM paired_macs ORDER BY pairedAtMs DESC LIMIT 1")
    suspend fun getLatest(): PairedMacEntity?

    @Upsert
    suspend fun upsert(mac: PairedMacEntity)

    @Delete
    suspend fun delete(mac: PairedMacEntity)

    @Query("DELETE FROM paired_macs WHERE macDeviceId = :id")
    suspend fun deleteById(id: String)
}

@Database(entities = [PairedMacEntity::class], version = 1, exportSchema = false)
abstract class CmuxDatabase : RoomDatabase() {
    abstract fun pairedMacDao(): PairedMacDao
}
